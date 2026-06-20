#!/usr/bin/env bash
# Provisions a GCP VM, builds BearBrowser from source (full Gecko + engine patches)
# for the given profiles, pulls back the binaries + fingerprint scorecards, and
# ALWAYS tears the VM down. The VM is Linux, so this produces Linux binaries (proves
# the patches + gives the scorecard); a runnable macOS app needs Apple hardware.
#
#   scripts/gcp-build-linux.sh --dry-run       # free: validate auth + resources
#   scripts/gcp-build-linux.sh                 # build human-secure + tor-mode
#   scripts/gcp-build-linux.sh --profiles human-secure --keep
#
# The build runs DETACHED on the VM and this script polls a status file, so a
# dropped SSH never kills the build or triggers an early teardown. Run the whole
# thing in the background (it takes ~2h for both profiles).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

INSTANCE="${BB_GCP_INSTANCE:-bearbrowser-build-$(date +%Y%m%d-%H%M%S)}"
ZONE="${BB_GCP_ZONE:-us-central1-a}"
MACHINE="${BB_GCP_MACHINE:-c2d-standard-32}"
IMAGE_FAMILY="${BB_GCP_IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${BB_GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
DISK_GB="${BB_GCP_DISK_GB:-150}"          # 2 full obj trees + toolchain fit in 150
MAX_HOURS="${BB_GCP_MAX_HOURS:-5}"         # safety cap; teardown fires regardless
PROFILES="${BB_PROFILES:-human-secure tor-mode}"
art_out="$repo_root/build/gcp-artifacts"
keep=""; dry_run=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profiles) PROFILES="${2:?}"; shift 2 ;;
    --machine)  MACHINE="${2:?}"; shift 2 ;;
    --zone)     ZONE="${2:?}"; shift 2 ;;
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    --disk-gb)  DISK_GB="${2:?}"; shift 2 ;;
    --keep)     keep="1"; shift ;;
    --dry-run)  dry_run="1"; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

created=""; SSHF=""   # SSHF gets "--tunnel-through-iap" if external SSH is blocked
cleanup() {
  local rc=$?
  if [ -n "$created" ] && [ -z "$keep" ]; then
    echo ">> Tearing down $INSTANCE ..."
    gcloud compute instances delete "$INSTANCE" --zone="$ZONE" --quiet 2>/dev/null \
      && echo ">> $INSTANCE deleted." \
      || { echo "!! WARNING: delete failed — $INSTANCE MAY STILL BE BILLING."; \
           echo "!! Run: gcloud compute instances delete $INSTANCE --zone=$ZONE --quiet"; }
  elif [ -n "$created" ]; then
    echo ">> --keep set: $INSTANCE left running in $ZONE (remember to delete it)."
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

vssh()  { gcloud compute ssh "$INSTANCE" --zone="$ZONE" $SSHF --command="$1" 2>/dev/null; }
vscp()  { gcloud compute scp $SSHF --zone="$ZONE" "$@" 2>/dev/null; }

# ── Preflight (all free — no VM yet) ────────────────────────────────────────
echo ">> Preflight..."
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "ERROR: gcloud is not authenticated (token expired)."
  echo "       Run:  gcloud auth login   (then: gcloud config set project <PROJECT>)"
  exit 1
fi
echo "   account: $(gcloud config get-value account 2>/dev/null)   project: $(gcloud config get-value project 2>/dev/null)"
gcloud compute machine-types describe "$MACHINE" --zone="$ZONE" --format='value(name)' >/dev/null 2>&1 \
  || { echo "ERROR: machine type '$MACHINE' not available in zone '$ZONE'."; exit 1; }
img="$(gcloud compute images describe-from-family "$IMAGE_FAMILY" --project="$IMAGE_PROJECT" --format='value(name)' 2>/dev/null)"
[ -n "$img" ] || { echo "ERROR: image family '$IMAGE_FAMILY' not found in '$IMAGE_PROJECT'."; exit 1; }
echo "   machine: $MACHINE   image: $img   disk: ${DISK_GB}GB   profiles: [$PROFILES]"
if [ -n "$dry_run" ]; then
  echo ">> DRY RUN OK — auth + machine type + image valid. No VM created, no cost."
  exit 0
fi

# ── Package the repo (exclude regen'able / huge dirs) ───────────────────────
echo ">> Packaging repo..."
tarball="/tmp/bb-repo-$$.tgz"
tar --exclude='./build' --exclude='./node_modules' --exclude='./.git' \
    --exclude='*.tar.gz' --exclude='*.tar.xz' -czf "$tarball" -C "$repo_root" . \
  || { echo "ERROR: repo tar failed"; exit 1; }
echo "   $(du -h "$tarball" | cut -f1)"

# ── Provision ───────────────────────────────────────────────────────────────
echo ">> Creating VM $INSTANCE ($MACHINE, $ZONE, ${DISK_GB}GB)..."
gcloud compute instances create "$INSTANCE" \
  --zone="$ZONE" --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-ssd --quiet \
  || { echo "ERROR: instance create failed"; exit 1; }
created="1"

# ── Wait for SSH; auto-detect external vs IAP ───────────────────────────────
echo ">> Waiting for SSH (auto-detecting external IP vs IAP)..."
ready=""
for i in $(seq 1 36); do
  for mode in "" "--tunnel-through-iap"; do
    if gcloud compute ssh "$INSTANCE" --zone="$ZONE" $mode --command='echo ready' 2>/dev/null | grep -q ready; then
      SSHF="$mode"; ready="1"
      echo "   SSH up via ${mode:-external-IP}."
      break 2
    fi
  done
  sleep 10
done
[ -n "$ready" ] || { echo "ERROR: SSH never came up (external or IAP)."; exit 1; }

# ── Upload + unpack ─────────────────────────────────────────────────────────
echo ">> Uploading repo..."
vscp "$tarball" "$INSTANCE":~/bb-repo.tgz || { echo "ERROR: scp failed"; exit 1; }
vssh 'rm -rf ~/BearBrowser ~/artifacts && mkdir -p ~/BearBrowser ~/artifacts && tar xzf ~/bb-repo.tgz -C ~/BearBrowser && echo unpacked' \
  | grep -q unpacked || { echo "ERROR: unpack failed"; exit 1; }

# ── Launch build DETACHED (survives SSH drops) ──────────────────────────────
echo ">> Launching detached build [$PROFILES]..."
vssh "cd ~/BearBrowser && nohup sh -c 'bash scripts/gcp-remote-build.sh \"$PROFILES\"; echo \$? > ~/artifacts/DONE' > ~/artifacts/build.log 2>&1 < /dev/null & echo launched" \
  | grep -q launched || { echo "ERROR: failed to launch build"; exit 1; }

# ── Poll until done (or safety cap) ─────────────────────────────────────────
echo ">> Building (polling every 60s; safety cap ${MAX_HOURS}h)..."
deadline=$(( $(date +%s) + MAX_HOURS*3600 ))
while :; do
  if vssh 'test -f ~/artifacts/DONE && echo done' | grep -q done; then echo "   build finished."; break; fi
  if [ "$(date +%s)" -gt "$deadline" ]; then echo "!! ERROR: build exceeded ${MAX_HOURS}h cap — tearing down."; break; fi
  echo "   [$(date -u +%H:%M:%S)] $(vssh 'tail -1 ~/artifacts/build.log 2>/dev/null')"
  sleep 60
done
build_rc="$(vssh 'cat ~/artifacts/DONE 2>/dev/null' | tr -dc 0-9)"; build_rc="${build_rc:-1}"

# ── Pull artifacts ──────────────────────────────────────────────────────────
mkdir -p "$art_out"
echo ">> Downloading artifacts to $art_out ..."
vscp --recurse "$INSTANCE":'~/artifacts/*' "$art_out/" || echo "   (no artifacts — check build.log)"
echo ">> Build finished (remote rc=$build_rc). Artifacts:"
ls -lh "$art_out" 2>/dev/null | sed 's/^/   /'
rm -f "$tarball"
exit "$build_rc"   # teardown runs in trap

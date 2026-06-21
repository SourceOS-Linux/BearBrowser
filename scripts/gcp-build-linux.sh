#!/usr/bin/env bash
# Builds BearBrowser from source on a GCP VM and pulls back binaries + fingerprint
# scorecards. NO SSH is used — this org blocks port 22 and OS Login key
# registration, so the VM is driven entirely through GCS + a startup script:
# upload repo -> VM builds autonomously -> VM pushes artifacts + DONE to GCS ->
# we poll GCS, download, and tear the VM down. (Linux binaries: proves the engine
# patches + gives the scorecard; a runnable macOS app needs Apple hardware.)
#
#   scripts/gcp-build-linux.sh --dry-run     # free: validate auth/machine/image/bucket
#   scripts/gcp-build-linux.sh               # build human-secure + tor-mode
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

INSTANCE="${BB_GCP_INSTANCE:-bearbrowser-build-$(date +%Y%m%d-%H%M%S)}"
ZONE="${BB_GCP_ZONE:-us-central1-a}"
MACHINE="${BB_GCP_MACHINE:-c2d-standard-32}"
IMAGE_FAMILY="${BB_GCP_IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${BB_GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
DISK_GB="${BB_GCP_DISK_GB:-150}"
MAX_HOURS="${BB_GCP_MAX_HOURS:-5}"
SERVICE_ACCOUNT="${BB_GCP_SA:-synapseiq-build@socioprophet-platform.iam.gserviceaccount.com}"
BUCKET="${BB_GCP_BUCKET:-sourceos-artifacts-socioprophet}"
PROFILES="${BB_PROFILES:-human-secure tor-mode}"
art_out="$repo_root/build/gcp-artifacts"
keep=""; dry_run=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profiles) PROFILES="${2:?}"; shift 2 ;;
    --machine)  MACHINE="${2:?}"; shift 2 ;;
    --zone)     ZONE="${2:?}"; shift 2 ;;
    --bucket)   BUCKET="${2:?}"; shift 2 ;;
    --instance) INSTANCE="${2:?}"; shift 2 ;;
    --keep)     keep="1"; shift ;;
    --dry-run)  dry_run="1"; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

PREFIX="gs://$BUCKET/bearbrowser-builds/$INSTANCE"
created=""
cleanup() {
  local rc=$?
  if [ -n "$created" ] && [ -z "$keep" ]; then
    echo ">> Tearing down $INSTANCE ..."
    gcloud compute instances delete "$INSTANCE" --zone="$ZONE" --quiet 2>/dev/null \
      && echo ">> $INSTANCE deleted." \
      || { echo "!! WARNING: delete failed — $INSTANCE MAY STILL BE BILLING."; \
           echo "!! Run: gcloud compute instances delete $INSTANCE --zone=$ZONE --quiet"; }
  elif [ -n "$created" ]; then
    echo ">> --keep set: $INSTANCE left running (remember to delete it)."
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ── Preflight (all free) ────────────────────────────────────────────────────
echo ">> Preflight..."
gcloud auth print-access-token >/dev/null 2>&1 \
  || { echo "ERROR: gcloud not authenticated. Run: gcloud auth login"; exit 1; }
echo "   account: $(gcloud config get-value account 2>/dev/null)   project: $(gcloud config get-value project 2>/dev/null)"
gcloud compute machine-types describe "$MACHINE" --zone="$ZONE" --format='value(name)' >/dev/null 2>&1 \
  || { echo "ERROR: machine type '$MACHINE' not available in '$ZONE'."; exit 1; }
img="$(gcloud compute images describe-from-family "$IMAGE_FAMILY" --project="$IMAGE_PROJECT" --format='value(name)' 2>/dev/null)"
[ -n "$img" ] || { echo "ERROR: image family '$IMAGE_FAMILY' not found."; exit 1; }
gcloud storage ls "gs://$BUCKET" >/dev/null 2>&1 \
  || { echo "ERROR: cannot access bucket gs://$BUCKET"; exit 1; }
echo "   machine: $MACHINE   image: $img   bucket: gs://$BUCKET   profiles: [$PROFILES]"
[ -f "$script_dir/gcp-vm-startup.sh" ] || { echo "ERROR: missing gcp-vm-startup.sh"; exit 1; }
if [ -n "$dry_run" ]; then echo ">> DRY RUN OK — auth + machine + image + bucket all valid. No VM, no cost."; exit 0; fi

# ── Package + upload repo to GCS ────────────────────────────────────────────
echo ">> Packaging + uploading repo to $PREFIX/bb-repo.tgz ..."
tarball="/tmp/bb-repo-$$.tgz"
tar --exclude='./build' --exclude='./node_modules' --exclude='./.git' \
    --exclude='*.tar.gz' --exclude='*.tar.xz' -czf "$tarball" -C "$repo_root" . \
  || { echo "ERROR: repo tar failed"; exit 1; }
gcloud storage cp "$tarball" "$PREFIX/bb-repo.tgz" >/dev/null 2>&1 \
  || { echo "ERROR: repo upload failed"; exit 1; }
rm -f "$tarball"
echo "   uploaded."

# ── Provision with startup script (no SSH) ──────────────────────────────────
echo ">> Creating VM $INSTANCE ($MACHINE, $ZONE, ${DISK_GB}GB)..."
gcloud compute instances create "$INSTANCE" \
  --zone="$ZONE" --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-ssd \
  --max-run-duration="$(( MAX_HOURS*3600 ))s" --instance-termination-action=DELETE \
  --service-account="$SERVICE_ACCOUNT" --scopes=cloud-platform \
  --metadata="bb-prefix=$PREFIX,bb-profiles=$PROFILES" \
  --metadata-from-file="startup-script=$script_dir/gcp-vm-startup.sh" \
  --quiet || { echo "ERROR: instance create failed"; exit 1; }
created="1"

# ── Poll GCS for the DONE marker (no SSH) ───────────────────────────────────
echo ">> Building on VM (polling GCS every 60s; safety cap ${MAX_HOURS}h)..."
deadline=$(( $(date +%s) + MAX_HOURS*3600 ))
build_rc="1"
while :; do
  if gcloud storage cat "$PREFIX/DONE" >/tmp/bb-done 2>/dev/null; then
    build_rc="$(tr -dc 0-9 </tmp/bb-done)"; build_rc="${build_rc:-0}"
    echo "   build finished (rc=$build_rc)."; break
  fi
  if [ "$(date +%s)" -gt "$deadline" ]; then echo "!! build exceeded ${MAX_HOURS}h cap — tearing down."; break; fi
  # progress from serial console (no SSH needed)
  line="$(gcloud compute instances get-serial-port-output "$INSTANCE" --zone="$ZONE" 2>/dev/null | grep -aE '===|profile|make build|BUILT|FAIL|OS-spoof' | tail -1)"
  echo "   [$(date -u +%H:%M:%S)] ${line:-(booting / installing toolchain…)}"
  sleep 60
done

# ── Collect artifacts from GCS ──────────────────────────────────────────────
mkdir -p "$art_out"
echo ">> Downloading artifacts from $PREFIX/ ..."
gcloud storage cp -r "$PREFIX/artifacts/*" "$art_out/" >/dev/null 2>&1 || echo "   (no artifacts — see build.log)"
gcloud storage cp "$PREFIX/build.log" "$art_out/build.log" >/dev/null 2>&1 || true
echo ">> Build finished (rc=$build_rc). Artifacts in $art_out:"
ls -lh "$art_out" 2>/dev/null | sed 's/^/   /'
exit "$build_rc"   # teardown in trap

#!/usr/bin/env bash
# VM startup script (runs as root at boot via instance metadata). No SSH is used —
# this org blocks port 22 + OS Login key registration, so the VM is fully
# autonomous: pull the repo from GCS, build (as a non-root user), push artifacts +
# a DONE marker back to GCS. The orchestrator polls GCS and tears the VM down.
set -uo pipefail
exec > >(tee /var/log/bb-build.log) 2>&1   # also visible via serial console
md() { curl -s -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

BUCKET_PREFIX="$(md bb-prefix)"   # gs://bucket/path/<ts>
PROFILES="$(md bb-profiles)"
echo "=== BearBrowser VM build start $(date -u) — prefix=$BUCKET_PREFIX profiles=[$PROFILES] ==="

# gsutil/gcloud: Ubuntu GCP images don't ship the CLI — install via snap.
if ! command -v gsutil >/dev/null 2>&1; then
  echo "=== installing google-cloud-cli ==="
  snap install google-cloud-cli --classic || { echo "FATAL: cannot install gcloud cli"; exit 1; }
fi

mark_done() { echo "$1" | gsutil cp - "$BUCKET_PREFIX/DONE" 2>/dev/null; }
push_log()  { gsutil cp /var/log/bb-build.log "$BUCKET_PREFIX/build.log" 2>/dev/null || true; }
trap 'push_log' EXIT

# Non-root build user (mach refuses to build as root); passwordless sudo for apt + mach bootstrap.
id builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder
echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder

echo "=== fetching repo from $BUCKET_PREFIX/bb-repo.tgz ==="
if ! gsutil cp "$BUCKET_PREFIX/bb-repo.tgz" /tmp/bb-repo.tgz; then echo "FATAL: repo fetch failed"; mark_done 90; exit 1; fi
sudo -u builder mkdir -p /home/builder/BearBrowser
tar xzf /tmp/bb-repo.tgz -C /home/builder/BearBrowser
chown -R builder:builder /home/builder/BearBrowser

echo "=== building (as builder): profiles [$PROFILES] ==="
su - builder -c "cd ~/BearBrowser && bash scripts/gcp-remote-build.sh '$PROFILES'"
rc=$?
echo "=== build finished rc=$rc ==="

echo "=== uploading artifacts to $BUCKET_PREFIX/artifacts/ ==="
gsutil -m cp -r /home/builder/artifacts/'*' "$BUCKET_PREFIX/artifacts/" 2>/dev/null || echo "WARN: artifact upload partial"
push_log
mark_done "$rc"
echo "=== DONE (rc=$rc) — orchestrator will collect + tear down ==="

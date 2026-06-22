#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
ref="latest"
zone="${GCP_ZONE:-us-central1-a}"
machine="${GCP_MACHINE:-c2d-standard-32}"
instance="${GCP_INSTANCE:-bearbrowser-build}"
project="${GCP_PROJECT:-}"
confirm="false"

usage() {
  cat <<USAGE
Usage: gcp-build-runner.sh [--profile P] [--ref R] [--zone Z] [--machine M] [--confirm]

Provisions a GCP build VM, compiles BearBrowser, pulls the artifact, and tears
the VM down. Estimated cost ~\$5-6 per run on c2d-standard-32.

Without --confirm this is a DRY RUN: it prints every gcloud command and exits
without creating any cloud resources or incurring cost.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:?}"; shift 2 ;;
    --ref)     ref="${2:?}"; shift 2 ;;
    --zone)    zone="${2:?}"; shift 2 ;;
    --machine) machine="${2:?}"; shift 2 ;;
    --confirm) confirm="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

run() {
  if [ "$confirm" = "true" ]; then
    echo "+ $*"
    "$@"
  else
    echo "  [dry-run] $*"
  fi
}

echo "BearBrowser GCP build runner"
echo "  profile=$profile ref=$ref zone=$zone machine=$machine instance=$instance"
echo "  confirm=$confirm  (est. cost ~\$5-6 when confirmed)"
echo ""

if [ "$confirm" != "true" ]; then
  echo "DRY RUN — no cloud resources will be created. Planned gcloud steps:"
fi

run gcloud compute instances create "$instance" \
  --zone="$zone" --machine-type="$machine" \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --boot-disk-size=120GB --boot-disk-type=pd-ssd ${project:+--project=$project}

# Wait for SSH, clone, build, pull artifact
remote_cmd="set -e; sudo apt-get update -q; sudo apt-get install -y git python3 mercurial build-essential; \
git clone https://github.com/SourceOS-Linux/BearBrowser.git; cd BearBrowser; \
bash scripts/bearbrowser-build-binary.sh --profile $profile --ref $ref"

run gcloud compute ssh "$instance" --zone="$zone" ${project:+--project=$project} --command="$remote_cmd"

run gcloud compute scp --recurse \
  "$instance:~/BearBrowser/build/workspaces/${profile}-*/source/obj-bearbrowser-${profile}/dist/*.tar.*" \
  "./dist/linux/" --zone="$zone" ${project:+--project=$project}

run gcloud compute instances delete "$instance" --zone="$zone" --quiet ${project:+--project=$project}

if [ "$confirm" != "true" ]; then
  echo ""
  echo "Dry run complete. Re-run with --confirm to provision and incur cost."
fi

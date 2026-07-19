# BearBrowser sovereign deploy manifests

Ready-to-apply manifests for the sovereign publish + search surfaces. Both are
committed here so nothing is stranded; each needs **one external input** (a
credential or a DNS record) that must be provided out-of-band before it goes live.

## `zot-publish-job.yaml` — binary → sovereign registry
Copies a built BearBrowser tarball from GCS staging into zot
(`registry.socioprophet.ai/bearbrowser/...`) as an OCI artifact, in-cluster (creds
never leave the cluster).

**Needs:**
1. `zot-push` secret — a dockerconfigjson for a zot **write** user (`admin`/`ci`/
   `github-ci`). Today only `zot-pull` (read-only `k8s-pull`) exists.
2. `gcs-build-key` secret — GCS objectViewer on
   `gs://sourceos-artifacts-socioprophet` (the build SA `synapseiq-build`).

Then: `kubectl apply -f deploy/sovereign/zot-publish-job.yaml` (edit `BUILD_TS`).

Current verified build to publish: `bearbrowser-build-20260718-175852`
(`bearbrowser-human-secure-linux-x86_64.tar.gz`, 731 MiB, anti-fp 12/20).

## `searxng-ingress.yaml` — public HTML search for the browser default engine
Exposes the existing `searxng` service (HTML SearXNG UI) at
`searx.socioprophet.ai` so it can be BearBrowser's default URL-bar engine. (The
cockpit Search *widget* uses the JSON `search-api.socioprophet.ai` directly and
needs no exposure.)

**Needs:** a DNS **A record** `searx.socioprophet.ai` → the ingress LB IP.
`socioprophet.ai` is on external DNS (not Cloud DNS), so this is a manual record.

Apply order (avoids the managed-cert `FailedNotVisible` trap):
1. `kubectl apply -f deploy/sovereign/searxng-ingress.yaml`
2. `kubectl get ingress searxng-public -n socioprophet` → note the LB IP
3. Add the A record at the socioprophet.ai DNS provider
4. The `searxng-cert` ManagedCertificate provisions once DNS resolves

Then flip BearBrowser's default engine to it (the engine definition is staged in
`settings/profiles/human-secure/policies.json` under `SearchEngines`, defaulted to
DuckDuckGo until `searx.socioprophet.ai` is live).

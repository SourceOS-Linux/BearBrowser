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

## Cockpit inline search (search-api CORS)
The cockpit start page (`native/macos/BearBrowser-start.html`) fetches
`search-api.socioprophet.ai` (JSON) and renders results inline, with a fallback to
the searx HTML surface. For the inline path to work from the browser, the cockpit's
**origin** must be in the gateway's CORS allowlist:
`prophet-platform/deploy/values/search-gateway.yaml` → `SEARCH_CORS_ORIGINS`
(currently the `.ai` + Firebase surfaces). Add the cockpit's **stable internal
origin** there once it exists — i.e. after the `resource://bearbrowser-cockpit` (or
`bearbrowser://`) origin from `docs/cockpit-spec.md` is wired. Do NOT add `null`
(file://) or `*` — that would open the API to any page. Until then the start page
falls back to the searx HTML surface (needs the DNS record above).

Note: the full cockpit app (`socioprophet-web/app-vue`) already ships a
`src/services/searchApi.ts` client for this gateway — the start page is the
lightweight bootstrap version of the same sovereign search surface.

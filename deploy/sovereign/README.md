# BearBrowser sovereign deploy manifests

Ready-to-apply manifests for the sovereign publish + search surfaces. Both are
committed here so nothing is stranded; each needs **one external input** (a
credential or a DNS record) that must be provided out-of-band before it goes live.

## Publish binary → sovereign registry (from CI)
Publishing is a CI job — `.github/workflows/publish-binary-to-zot.yml` — that pulls
the built tarball from GCS staging and `oras push`es it to zot
(`registry.socioprophet.ai/bearbrowser/<profile>-linux-x86_64:<version>`) as an OCI
artifact, using the estate's existing zot CI credentials (same as
`prophet-platform/images.yml`).

**One-time secrets on this repo / the SourceOS-Linux org** (you have the values):
`ZOT_CI_USERNAME`, `ZOT_CI_PASSWORD` (github-ci write user) and
`GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` (WIF with objectViewer on
`gs://sourceos-artifacts-socioprophet`).

Then:
`gh workflow run "Publish binary to zot" -f build_ts=bearbrowser-build-20260718-175852 -f version=0.1.0`

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

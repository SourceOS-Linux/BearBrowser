# BearBrowser sovereign deploy manifests

Ready-to-apply manifests for the sovereign publish + search surfaces. Both are
committed here so nothing is stranded; each needs **one external input** (a
credential or a DNS record) that must be provided out-of-band before it goes live.

## Binary distribution — via the established pipeline, not a bespoke publish
Binaries are NOT hand-pushed to zot. The estate's pipeline is: build → GCS →
record the build in `packaging/linux/binary-source.env` (BUILD_ID + per-variant
SHA256) → the deb/snap/appimage/flatpak/rpm packaging lanes fetch from that GCS
path. To ship a new build, run the build (both variants) and update
`binary-source.env` — that is the single source of truth. (An earlier bespoke
`publish-binary-to-zot.yml` workflow was removed; it duplicated this with new
secrets.)

## `searxng-ingress.yaml` — public HTML search for the browser default engine
Exposes the existing `searxng` service (HTML SearXNG UI) at
`searx.socioprophet.ai` so it can be BearBrowser's default URL-bar engine. (The
cockpit Search *widget* uses the JSON `search-api.socioprophet.ai` directly and
needs no exposure.)

**Needs:** a DNS **A record** `searx.socioprophet.ai` → the ingress LB IP.
`socioprophet.ai` is on external DNS (not Cloud DNS), so this is a manual record.

APPLIED (HTTP-only, cert held): the ingress `searxng-public` is live in the
`socioprophet` ns. **LB IP: `8.232.89.217`.**

Remaining (avoids the managed-cert `FailedNotVisible` trap):
1. Add the DNS A record:  `searx.socioprophet.ai  A  8.232.89.217`
2. Once it resolves, apply the cert (adds HTTPS):
   `kubectl apply -f deploy/sovereign/searxng-ingress.yaml`
   (the committed manifest includes the `searxng-cert` ManagedCertificate +
   the managed-certificates annotation — safe to apply only after DNS resolves)

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

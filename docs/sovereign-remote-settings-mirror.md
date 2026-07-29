# Sovereign RemoteSettings mirror — resolving privacy vs. security

## The false dilemma
Two hardening steps looked like they cost security:

1. Blanking `services.settings.server` kills Mozilla RemoteSettings — which also
   delivers **CRLite certificate-revocation filters**, intermediate-CA
   preloading and CT logs. `security.pki.crlite_mode=2` is *enforcing*, and
   `security.OCSP.require=false`, so losing CRLite genuinely weakens revocation.
2. Blanking `extensions.update.*` freezes installed add-ons on versions with
   known vulnerabilities.

Both only look like trades because Mozilla serves **security data and product
junk from the same endpoint**. Separate them and the dilemma disappears.

## The optimal architecture: mirror the security collections, drop the rest
Point `services.settings.server` at **our** host and serve **only**:

| Collection | Why we keep it |
|---|---|
| `security-state/cert-revocations` | CRLite revocation (the actual security value) |
| `security-state/intermediates` | intermediate-CA preloading |
| `security-state/ct-logs` | Certificate Transparency log list |
| `blocklists/addons`, `blocklists/plugins` | malicious add-on/plugin blocking |
| `main/tracking-protection-lists` | anti-tracking |
| `main/query-stripping`, `main/anti-tracking-url-decoration` | URL de-decoration |
| `main/hijack-blocklists` | search-hijack protection |

Everything else — `pioneer-*`, `rally-studies-*`, `nimbus-*`, `*-experiments`,
`cfr*`, `quicksuggest-*`, `personality-provider-*`, `newtab-*sponsors`,
`ms-images`, `tippytop`, `whats-new-panel`, `devtools-news`,
`sites-classification` — is simply **not served**. It cannot be re-enabled
because it does not exist on our endpoint.

### Why this is strictly better than either horn
- **Security preserved** — we still get revocation, CT and blocklists.
- **Privacy preserved** — Mozilla sees **one** mirror fetching on a schedule,
  never individual users. No per-install `%OS_VERSION%`/`%BUILD_ID%` beacons.
- **Tamper-resistant without trusting ourselves** — RemoteSettings records carry
  Mozilla's **content signature**, verified client-side against a pinned chain.
  A mirror (ours or anyone's) *cannot* forge records. So mirroring costs no
  integrity: we relay bytes we cannot alter undetected.
  (Corollary: `security.content_signature.root_hash` must stay intact — do not
  "helpfully" disable signature checks to make a mirror easier. That would
  convert a safe relay into a real attack surface.)
- **Reproducible** — the upstream artifacts are public; the mirror is a dumb,
  auditable sync job. Same doctrine as zot/MinIO replacing GHCR+GAR.

## Add-on updates
Same shape: mirror the AMO update manifests for the add-ons we bless, and point
`extensions.update.url` at the mirror. Add-ons keep receiving security updates;
AMO stops seeing per-user version-check beacons (which today leak `appOS`,
`appABI`, `locale` and both app and add-on versions).

## Until the mirror exists
Current, deliberate state — **stated, not hidden**:
- `services.settings.server` — **left alone**. CRLite keeps working.
- `extensions.update.*` — **left alone**. Add-ons keep getting security updates.
- Every *junk* feature riding RemoteSettings is disabled by pref anyway
  (Pioneer, Rally, Normandy, Shield, CFR, quicksuggest, discoverystream,
  personality provider, translations), so the collections may be *requested* but
  nothing consumes them.
- `security.OCSP.require` stays **false**: hard-failing on an unreachable OCSP
  responder breaks browsing on flaky networks, and CRLite already covers
  revocation. **If we ever lose CRLite, flip it to true** — that is the
  compensating control.

## Build order
1. Stand up the mirror (static signed-artifact sync + HTTPS host).
2. Verify content-signature validation passes against the mirror **before**
   repointing anything.
3. Repoint `services.settings.server`, then `extensions.update.url`.
4. Re-run `scripts/audit/` and confirm no regression.

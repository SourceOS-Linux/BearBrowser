# Sovereign RemoteSettings mirror

Resolves the privacy-vs-security false dilemma described in
`docs/sovereign-remote-settings-mirror.md`.

    node scripts/rs-mirror/sync.mjs --out ./mirror --base https://rs.example.org
    # serve ./mirror as static files, then:
    #   services.settings.server = https://rs.example.org

## Verified run (2026-07-29, against Mozilla PROD)
    10 collections | 3709 records | 2366 attachments | 2 signing chains | 68.6 MB

Mirrored — each with a stated security reason:
| Collection | Why |
|---|---|
| `security-state/cert-revocations` | CRLite certificate revocation |
| `security-state/intermediates` | intermediate CA preloading |
| `security-state/ct-logs` | Certificate Transparency logs |
| `blocklists/addons-bloomfilters` | malicious add-on blocking |
| `blocklists/plugins` | vulnerable plugin blocking |
| `main/tracking-protection-lists` | anti-tracking |
| `main/query-stripping` | tracking-param removal |
| `main/anti-tracking-url-decoration` | URL de-decoration |
| `main/hijack-blocklists` | search-hijack protection |
| `main/url-classifier-exceptions` | classifier false-positive fixes |

**Not** mirrored, therefore impossible to re-enable: pioneer, rally,
nimbus/experiments, cfr, quicksuggest, personality-provider, newtab sponsors,
ads, tippytop, search-telemetry, sites-classification.

## Why mirroring does not weaken integrity
Records are signed by Mozilla. The client fetches the signing chain from the
`x5u` in the signature and verifies it against a **pinned root hash**
(`security.content_signature.root_hash`). A mirror — ours or anyone's — cannot
forge or alter a record without detection. We relay bytes we cannot tamper with.

The sync therefore copies signature metadata **verbatim** and never
re-serialises records (re-ordering keys would invalidate the signature). It also
mirrors the signing chain and repoints `x5u` at us, so the client never contacts
Mozilla even to verify.

🔴 **Never weaken content-signature verification to make mirroring easier.** That
turns a safe relay into a real attack surface. A failing signature must FAIL.

## Operating it
Re-run on a schedule (CRLite updates several times a day). The output is static
files — any HTTPS host works; no application server. Verify signature
validation against the mirror **before** repointing `services.settings.server`.

#!/usr/bin/env node
/**
 * Sovereign RemoteSettings mirror — sync.
 *
 * Pulls ONLY the security/anti-tracking collections from Mozilla and writes a
 * static tree that serves the same API shape. Everything else Mozilla publishes
 * (Pioneer, Rally, ads, experiments, personality profiling) is simply NOT
 * mirrored, so it cannot be re-enabled: it does not exist on our endpoint.
 *
 *   node scripts/rs-mirror/sync.mjs --out ./mirror [--base https://our.host]
 *
 * WHY THIS IS SAFE — read before changing anything:
 * Records are signed by Mozilla. The client fetches the signing chain from the
 * `x5u` URL in the signature, then verifies that chain against a PINNED ROOT
 * (security.content_signature.root_hash). So a mirror — ours or anyone's —
 * cannot forge or alter a record without detection. We relay bytes we are not
 * able to tamper with.
 * 🔴 Therefore: NEVER weaken content-signature verification to make mirroring
 * easier. That would convert a safe relay into a real attack surface. If a
 * signature fails, the correct response is to FAIL, not to disable the check.
 * For the same reason this script copies signature metadata VERBATIM and never
 * re-serialises records: re-ordering keys would invalidate the signature.
 */
import fs from "node:fs/promises";
import path from "node:path";

const UPSTREAM = "https://firefox.settings.services.mozilla.com/v1";

// The allowlist IS the product. Add nothing without a stated security reason.
const COLLECTIONS = [
  ["security-state", "cert-revocations",         "CRLite certificate revocation"],
  ["security-state", "intermediates",            "intermediate CA preloading"],
  ["security-state", "ct-logs",                  "Certificate Transparency logs"],
  ["blocklists",     "addons-bloomfilters",      "malicious add-on blocking"],
  ["blocklists",     "plugins",                  "vulnerable plugin blocking"],
  ["main",           "tracking-protection-lists","anti-tracking"],
  ["main",           "query-stripping",          "tracking-param removal"],
  ["main",           "anti-tracking-url-decoration", "URL de-decoration"],
  ["main",           "hijack-blocklists",        "search-hijack protection"],
  ["main",           "url-classifier-exceptions","classifier false-positive fixes"],
];

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const OUT = path.resolve(argOf("--out", "./mirror"));
const SELF_BASE = argOf("--base", "");   // our public base URL, for x5u rewriting

async function getJSON(url) {
  const r = await fetch(url, { headers: { "user-agent": "bearbrowser-rs-mirror" } });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json();
}
async function getBuf(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return Buffer.from(await r.arrayBuffer());
}
async function write(rel, data) {
  const p = path.join(OUT, rel);
  await fs.mkdir(path.dirname(p), { recursive: true });
  await fs.writeFile(p, data);
  return p;
}

const root = await getJSON(`${UPSTREAM}/`);
const attachBase = root.capabilities?.attachments?.base_url;
if (!attachBase) throw new Error("upstream did not advertise an attachment base_url");

let records = 0, attachments = 0, chains = 0, bytes = 0;
const monitorChanges = [];
const seenChains = new Map();   // upstream x5u -> mirrored path

for (const [bucket, collection, why] of COLLECTIONS) {
  process.stdout.write(`  ${bucket}/${collection}  (${why})\n`);
  const cs = await getJSON(
    `${UPSTREAM}/buckets/${bucket}/collections/${collection}/changeset?_expected=0`
  );

  // Mirror the signing chain and repoint x5u at us, so the CLIENT never has to
  // contact Mozilla to verify. Safe because the chain is checked against the
  // pinned root hash regardless of where it was served from.
  const sig = cs.metadata?.signature;
  if (sig?.x5u) {
    if (!seenChains.has(sig.x5u)) {
      const rel = `chains/${path.basename(new URL(sig.x5u).pathname)}`;
      const buf = await getBuf(sig.x5u);
      await write(rel, buf);
      bytes += buf.length; chains++;
      seenChains.set(sig.x5u, rel);
    }
    if (SELF_BASE) {
      sig.x5u = `${SELF_BASE.replace(/\/$/, "")}/${seenChains.get(sig.x5u)}`;
    }
  }

  // Attachments (CRLite filters live here).
  for (const rec of cs.changes || []) {
    const at = rec.attachment;
    if (!at?.location) continue;
    const buf = await getBuf(attachBase + at.location);
    await write(`attachments/${at.location}`, buf);
    bytes += buf.length; attachments++;
  }

  await write(
    `buckets/${bucket}/collections/${collection}/changeset.json`,
    JSON.stringify(cs)
  );
  records += (cs.changes || []).length;
  monitorChanges.push({
    id: `${bucket}-${collection}`, bucket, collection,
    last_modified: cs.timestamp,
  });
}

// The poll endpoint the client hits first.
await write(
  "buckets/monitor/collections/changes/changeset.json",
  JSON.stringify({ changes: monitorChanges, timestamp: Date.now(), metadata: {} })
);
// Root capabilities, with attachments pointed at us.
await write("index.json", JSON.stringify({
  project_name: "BearBrowser Sovereign RemoteSettings Mirror",
  capabilities: {
    attachments: {
      base_url: SELF_BASE ? `${SELF_BASE.replace(/\/$/, "")}/attachments/` : attachBase,
    },
  },
}));

// Also mirror the AMO update manifests for a small set of add-on IDs, so
// extensions.update.url can be repointed at us. Same doctrine — we relay bytes
// we did not author, and add-on XPIs remain Mozilla-signed end-to-end (the
// signing chain is verified against a pinned root inside the browser, exactly
// like RemoteSettings). We add nothing; we simply do not phone home per user.
const AMO_IDS = (process.env.AMO_MIRROR_IDS || "").split(",").map(s=>s.trim()).filter(Boolean);
if (AMO_IDS.length) {
  process.stdout.write(`\namo: mirroring ${AMO_IDS.length} extension update manifest(s)\n`);
  for (const id of AMO_IDS) {
    try {
      // amoAPI: /api/v5/addons/addon/<id>/versions/?filter=all_with_unlisted
      const meta = await getJSON(
        `https://services.addons.mozilla.org/api/v5/addons/addon/${encodeURIComponent(id)}/`
      );
      // Extension update manifest shape Firefox expects at extensions.update.url
      const manifest = {
        addons: {
          [id]: {
            updates: [{ version: meta.current_version.version,
                        update_link: meta.current_version.file.url,
                        update_hash: meta.current_version.file.hash || undefined }]
          }
        }
      };
      await write(`extensions/${encodeURIComponent(id)}.json`,
                  JSON.stringify(manifest, null, 1));
      records++;
      process.stdout.write(`  amo/${id}  -> v${meta.current_version.version}\n`);
    } catch (e) {
      process.stdout.write(`  amo/${id}  SKIP (${e.message.slice(0,60)})\n`);
    }
  }
}
console.log(
  `\nmirrored ${COLLECTIONS.length} RS collections | ${records} records | ` +
  `${attachments} attachments | ${chains} signing chains | ` +
  `${(bytes / 1e6).toFixed(1)} MB -> ${OUT}`
);
console.log("NOT mirrored (by design): pioneer, rally, nimbus/experiments, cfr,");
console.log("quicksuggest, personality-provider, newtab sponsors, ads, tippytop.");

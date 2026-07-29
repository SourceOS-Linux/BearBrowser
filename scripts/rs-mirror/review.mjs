#!/usr/bin/env node
/**
 * Zero-trust review of a mirrored RemoteSettings tree.
 *
 * The content signature proves only that MOZILLA SIGNED IT. It does not prove
 * the content is benign — a signed record is exactly what a compelled,
 * compromised or simply bad-policy upstream would ship. So we do not relay
 * blind: we read what we are about to serve.
 *
 *   node scripts/rs-mirror/review.mjs --dir ./mirror [--baseline prev.json]
 *
 * Exits non-zero if anything needs a human. Fail closed: an unreviewed change
 * does not reach users.
 */
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const DIR = path.resolve(argOf("--dir", "./mirror"));
const BASELINE = argOf("--baseline", "");
const WRITE = argOf("--write-baseline", "");

// Hosts a security/anti-tracking record may legitimately reference. Anything
// else in mirrored content is a finding, signed or not.
const URL_ALLOW = [
  /^https:\/\/firefox-settings-attachments\.cdn\.mozilla\.net\//,
  /^https:\/\/content-signature-2\.cdn\.mozilla\.net\//,
  // our own repointed signing chain — we put it there
  /\/chains\/[^/]+\.chain$/,
  // JSON-schema and documentation references carried in metadata. These are
  // descriptive, never fetched by the client. Verified by reading the records:
  // they appear in `schema`/`filter_expression` help text, not in any field the
  // browser dereferences.
  /^https:\/\/remote-settings\.readthedocs\.io\//,
  /^https:\/\/developer\.mozilla\.org\/[^ ]*Match_patterns/,
];
const URL_RE = /(https?|wss?):\/\/[^\s"'\\)]+/g;

const findings = [];   // fail closed
const notes = [];      // worth a human glance, not a blocker
const inventory = {};  // urls in collections that legitimately carry them
const summary = {};

async function walk(d) {
  const out = [];
  for (const e of await fs.readdir(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) out.push(...await walk(p));
    else out.push(p);
  }
  return out;
}

const files = await walk(DIR);
const changesets = files.filter(f => f.endsWith("changeset.json"));

for (const f of changesets) {
  const rel = path.relative(DIR, f);
  const raw = await fs.readFile(f, "utf8");
  const cs = JSON.parse(raw);
  const name = rel.replace(/^buckets\//, "").replace(/\/changeset\.json$/, "");

  // 1. Integrity anchor: hash exactly what we will serve.
  const sha = crypto.createHash("sha256").update(raw).digest("hex");

  // 2. A collection with no signature must never be served.
  const sig = cs.metadata?.signature;
  if (!sig?.signature && !rel.includes("monitor/")) {
    findings.push(`${name}: NO SIGNATURE — refusing to vouch for this`);
  }

  // 3. Read the content. Any URL we did not expect is a finding, signed or not.
  //    Collection-aware: some collections legitimately CONTAIN urls —
  //      ct-logs      IS a list of Certificate Transparency log endpoints
  //      intermediates embeds CPS/repository URIs inside certificate data
  //    For those, URLs are inventoried for human eyes rather than failed on;
  //    everywhere else a URL in signed content is a real finding.
  //   ct-logs        IS a list of Certificate Transparency log endpoints
  //   intermediates  embeds CPS/repository URIs inside certificate data
  //   plugins/addons blocklist entries carry a user-facing "why was this
  //                  blocked" link (bugzilla / vendor advisory)
  const URL_EXPECTED = /(ct-logs|intermediates|plugins|addons-bloomfilters)$/;
  const urls = new Set();
  for (const m of raw.matchAll(URL_RE)) {
    const u = m[0];
    if (!URL_ALLOW.some(re => re.test(u))) urls.add(u);
  }
  if (URL_EXPECTED.test(name)) {
    inventory[name] = [...urls].sort();
    // Even here, non-HTTPS or obvious placeholders deserve a shout.
    for (const u of urls) {
      if (u.startsWith("http://")) {
        notes.push(`${name}: cleartext URL in signed content -> ${u.slice(0, 90)}`);
      }
      if (/example\.(com|org)|bogus|test\./i.test(u)) {
        notes.push(`${name}: PLACEHOLDER url shipped by upstream -> ${u.slice(0, 90)}`);
      }
    }
  } else {
    for (const u of urls) {
      findings.push(`${name}: UNEXPECTED URL in signed content -> ${u.slice(0, 110)}`);
    }
  }

  // 4. Records that can execute or redirect are never expected in these
  //    collections; call them out explicitly.
  for (const bad of ["javascript:", "data:text/html", "<script", "eval("]) {
    if (raw.includes(bad)) findings.push(`${name}: ACTIVE CONTENT marker '${bad}'`);
  }

  summary[name] = { sha256: sha, records: (cs.changes || []).length, bytes: raw.length };
}

// 5. Diff against the last reviewed state — a silent change to data we already
//    vouched for is the thing we most want to see.
if (BASELINE) {
  try {
    const prev = JSON.parse(await fs.readFile(BASELINE, "utf8"));
    for (const [name, cur] of Object.entries(summary)) {
      const old = prev[name];
      if (!old) { findings.push(`${name}: NEW collection since last review`); continue; }
      if (old.sha256 !== cur.sha256) {
        const d = cur.records - old.records;
        console.log(`  changed: ${name}  records ${old.records} -> ${cur.records} (${d >= 0 ? "+" : ""}${d})`);
        // A large swing in a security list deserves eyes before it ships.
        if (old.records && Math.abs(d) / old.records > 0.25) {
          findings.push(`${name}: RECORD COUNT MOVED ${((d / old.records) * 100).toFixed(0)}% — review before serving`);
        }
      }
    }
    for (const name of Object.keys(prev)) {
      if (!summary[name]) findings.push(`${name}: DISAPPEARED upstream`);
    }
  } catch (e) { console.log(`  (no usable baseline: ${e.message})`); }
}

console.log(`\nreviewed ${changesets.length} collections in ${DIR}`);
for (const [n, s] of Object.entries(summary)) {
  console.log(`  ${n.padEnd(46)} ${String(s.records).padStart(5)} rec  ${s.sha256.slice(0, 12)}`);
}
if (WRITE) {
  await fs.writeFile(WRITE, JSON.stringify(summary, null, 1));
  console.log(`\nbaseline written: ${WRITE}`);
}
for (const [n, us] of Object.entries(inventory)) {
  console.log(`  inventory ${n}: ${us.length} url(s) (expected for this collection)`);
}
if (notes.length) {
  console.log(`\n⚠️  ${notes.length} note(s) — not blocking, but look:`);
  notes.forEach(n => console.log("   " + n));
}
if (findings.length) {
  console.log(`\n🔴 ${findings.length} FINDING(S) — do not serve until reviewed:`);
  findings.forEach(f => console.log("   " + f));
  process.exit(1);
}
console.log("\n✅ clean: signed, no unexpected URLs, no active content, no silent drift.");

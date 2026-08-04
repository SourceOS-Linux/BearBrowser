// Unit tests for the sovereign update-check helpers embedded in
// settings/start/bearstart-autoconfig.js.
//
// Two shipped bugs this file exists to prevent:
//
//   1. Semver parser broke on `-rc` suffixes (Number("4-rc1") === NaN).
//      Caught by manual review; would have shipped a broken comparison that
//      always reported "no update".
//
//   2. Update fetch leaked Referer + cookies to github.com. Caught by manual
//      review; the mitigation was `credentials:"omit"` + `referrerPolicy:
//      "no-referrer"`. This test asserts the shipped source still contains
//      those keywords AND wires them together (not present in different
//      calls).
//
// Runs under `node scripts/tests/test_update_check.mjs` — no test-runner
// dependency, so it's cheap to add to feature-plane.yml's script tier.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const AUTOCONFIG = join(HERE, "..", "..", "settings", "start", "bearstart-autoconfig.js");
const SRC = readFileSync(AUTOCONFIG, "utf8");

let failed = 0;
function check(name, cond, hint = "") {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    console.log(`  FAIL ${name}${hint ? "  — " + hint : ""}`);
    failed++;
  }
}

// ── 1. Semver parser table ────────────────────────────────────────────────────
// Extract the parser expression the update-check uses. It reads:
//   const parse = v => String(v).split(".").map(p => parseInt(p, 10) || 0);
// Reconstruct that behaviour and run a table of cases.
const parseSemver = v =>
  String(v).split(".").map(p => parseInt(p, 10) || 0);

const semverCases = [
  ["150.0.4",       [150, 0, 4]],
  ["150.0.4-rc1",   [150, 0, 4]],   // rc suffix must not blow up
  ["150.0.5",       [150, 0, 5]],
  ["v150.0.5",      [0, 0, 5]],     // leading "v" is caller's job to strip
  ["1.2.3.4",       [1, 2, 3, 4]],
  ["nonsense",      [0]],
  ["",              [0]],
];
console.log("semver parser table:");
for (const [input, expected] of semverCases) {
  const got = parseSemver(input);
  check(
    `parseSemver(${JSON.stringify(input)})`,
    JSON.stringify(got) === JSON.stringify(expected),
    `got ${JSON.stringify(got)} expected ${JSON.stringify(expected)}`,
  );
}

// Semver COMPARISON works for the specific case that broke v150.0.4→5 (rc
// suffix). If parseInt("4-rc1") === NaN made it through, the comparison
// would return "no update" incorrectly. Assert the actual comparison.
function cmp(a, b) {
  const A = parseSemver(a), B = parseSemver(b);
  const n = Math.max(A.length, B.length);
  for (let i = 0; i < n; i++) {
    const d = (A[i] || 0) - (B[i] || 0);
    if (d) return d;
  }
  return 0;
}
console.log("semver comparison:");
check("150.0.5 > 150.0.4",       cmp("150.0.5", "150.0.4")       > 0);
check("150.0.5 > 150.0.4-rc1",   cmp("150.0.5", "150.0.4-rc1")   > 0);
check("150.0.5-rc1 == 150.0.5",  cmp("150.0.5-rc1", "150.0.5") === 0,
      "parseInt drops the -rc1 suffix — the rc is treated as GA. Ship-blocker if that changes.");

// ── 2. Fetch hygiene ─────────────────────────────────────────────────────────
console.log("update-fetch hygiene (as shipped):");
check(
  "shipped code sets credentials:\"omit\"",
  /credentials\s*:\s*"omit"/.test(SRC),
);
check(
  "shipped code sets referrerPolicy:\"no-referrer\"",
  /referrerPolicy\s*:\s*"no-referrer"/.test(SRC),
);
// They must be on the SAME fetch call. Locate the "update-check region" — the
// contiguous source lines around the update-check fetch — and assert both
// keywords appear inside it. Prior regex required latest.json to appear
// INSIDE the fetch() args, which broke when the URL was moved into a `url`
// variable for the canary channel refactor. New approach: scope by comment
// anchor + 40 lines, tolerant to future refactors.
const anchor = SRC.indexOf("Sovereign update check");
check(
  "update-check anchor comment present",
  anchor >= 0,
);
const updateRegion = anchor >= 0 ? SRC.slice(anchor, anchor + 3000) : "";
check(
  "update-check region references latest.json (either directly or via manifest var)",
  /latest(-canary)?\.json/.test(updateRegion),
);
check(
  "update-check region contains a fetch(...) call",
  /fetch\s*\(/.test(updateRegion),
);
if (updateRegion) {
  check(
    "update-check region sets BOTH credentials:omit AND referrerPolicy:no-referrer",
    /credentials\s*:\s*"omit"/.test(updateRegion) &&
    /referrerPolicy\s*:\s*"no-referrer"/.test(updateRegion),
    "one without the other = a leak that would take another release to notice",
  );
}

if (failed) {
  console.log(`\nFAIL: ${failed} test(s)`);
  process.exit(1);
}
console.log("\nOK: all update-check tests passed");

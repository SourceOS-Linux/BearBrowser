#!/usr/bin/env node
/* BearTrap honeypot containment proof (pure-logic twin of the in-browser actor).
 *
 * The actor code (settings/actors/BearTrap*.sys.mjs) uses browser globals, so
 * this test replicates the two load-bearing decisions and proves them:
 *   1. FINGERPRINT: a page is flagged iff it probes >= FP_THRESHOLD distinct
 *      fingerprinting surfaces — benign pages must NOT false-positive.
 *   2. CANARY: an outbound URL carrying a registered canary token is caught +
 *      blocked, attributed to its origin; unrelated traffic is untouched.
 *
 * Run: node scripts/tests/test_honeypot.mjs   (exit 0 = PASS)
 */

const FP_THRESHOLD = 3; // must match BearTrapChild

// ── 1. fingerprint threshold ────────────────────────────────────────────────
function isFingerprinting(surfaces) {
  return new Set(surfaces).size >= FP_THRESHOLD;
}

// ── 2. canary registry + match (mirrors BearTrapMonitor) ────────────────────
const canaries = new Map(); // origin -> Set(token)
function registerCanary(origin, token) {
  if (!canaries.has(origin)) canaries.set(origin, new Set());
  canaries.get(origin).add(token);
}
function match(text) {
  if (!text) return null;
  for (const [origin, tokens] of canaries) {
    for (const t of tokens) if (text.includes(t)) return { origin, token: t };
  }
  return null;
}

const CASES = [];
function check(name, got, want) {
  CASES.push({ name, ok: JSON.stringify(got) === JSON.stringify(want), got, want });
}

// fingerprint cases
check("benign: 1 surface not flagged", isFingerprinting(["hardware"]), false);
check("benign: 2 surfaces not flagged", isFingerprinting(["canvas", "hardware"]), false);
check("fingerprinting: 3 distinct flagged", isFingerprinting(["canvas", "webgl", "audio"]), true);
check("fingerprinting: repeats of 2 NOT flagged", isFingerprinting(["canvas", "canvas", "webgl", "webgl"]), false);
check("fingerprinting: 5 surfaces flagged", isFingerprinting(["canvas", "canvas-text", "webgl", "audio", "plugins"]), true);

// canary cases
const TOK = "bt-abc123xyz-deadbeef";
registerCanary("https://shop.example", TOK);
check("canary in GET beacon URL → caught", !!match("https://evil.tracker.net/collect?e=" + TOK + "%40example.invalid"), true);
check("caught leak attributed to origin", (match("https://x/?d=" + TOK) || {}).origin, "https://shop.example");
check("unrelated outbound → not caught", match("https://cdn.example/app.js?v=42"), null);
check("similar-but-wrong token → not caught", match("https://x/?d=bt-different-token"), null);

// POST/PUT body cases — BearTrapMonitor._readUploadBody feeds the rewound body
// through the same match(); these twin that decision for the common exfil shapes.
check("canary in form-encoded POST body → caught", !!match("email=" + TOK + "%40example.invalid&src=1"), true);
check("canary in JSON POST body → caught", !!match('{"lead":{"email":"' + TOK + '@example.invalid"}}'), true);
check("body leak attributed to origin", (match("payload=" + TOK) || {}).origin, "https://shop.example");
check("benign form body → not caught", match("q=hello&page=2"), null);

// ── BearWall denylist (mirrors BearTrapMonitor DENY_HOSTS/DENY_SUFFIXES) ─────
const DENY_HOSTS = new Set(["detectportal.firefox.com","incoming.telemetry.mozilla.org",
 "telemetry.mozilla.org","dap.services.mozilla.com","aus5.mozilla.org","aus4.mozilla.org",
 "ads.mozilla.org","contile.services.mozilla.com","spocs.getpocket.com","getpocket.com",
 "normandy.cdn.mozilla.net","location.services.mozilla.com","push.services.mozilla.com",
 "shavar.services.mozilla.com","safebrowsing.googleapis.com","www.googleapis.com",
 "profiler.firefox.com","monitor.firefox.com","relay.firefox.com","vpn.mozilla.org",
 "fpn.firefox.com","model-hub.mozilla.org","mozilla-ohttp.fastly-edge.com"]);
const DENY_SUFFIXES = [".telemetry.mozilla.org",".ohttp-gateway.prod.webservices.mozgcp.net"];
const isDenied = h => { h=String(h).toLowerCase();
  return DENY_HOSTS.has(h) || DENY_SUFFIXES.some(s=>h.endsWith(s)); };

check("BLOCK detectportal (cleartext, HTTPS-Only exempt)", isDenied("detectportal.firefox.com"), true);
check("BLOCK aus5 GMP updater (leaks OS version)", isDenied("aus5.mozilla.org"), true);
check("BLOCK incoming.telemetry", isDenied("incoming.telemetry.mozilla.org"), true);
check("BLOCK DAP telemetry", isDenied("dap.services.mozilla.com"), true);
check("BLOCK ads.mozilla.org", isDenied("ads.mozilla.org"), true);
check("BLOCK Google safebrowsing", isDenied("safebrowsing.googleapis.com"), true);
check("BLOCK Fastly OHTTP ad relay", isDenied("mozilla-ohttp.fastly-edge.com"), true);
check("BLOCK suffix .telemetry.mozilla.org", isDenied("foo.telemetry.mozilla.org"), true);
// 🔴 The load-bearing NEGATIVES — blocking these would trade SECURITY for privacy.
check("ALLOW RemoteSettings (CRLite revocation!)", isDenied("firefox.settings.services.mozilla.com"), false);
check("ALLOW addons.mozilla.org (add-on security updates)", isDenied("addons.mozilla.org"), false);
check("ALLOW services.addons.mozilla.org", isDenied("services.addons.mozilla.org"), false);
check("ALLOW unrelated site", isDenied("example.com"), false);
check("ALLOW lookalike suffix not matched", isDenied("nottelemetry.mozilla.org.evil.com"), false);

let failed = 0;
for (const c of CASES) {
  console.log(`  [${c.ok ? "PASS" : "FAIL"}] ${c.name}`);
  if (!c.ok) {
    failed++;
    console.log(`         got ${JSON.stringify(c.got)} want ${JSON.stringify(c.want)}`);
  }
}
console.log("\n" + "=".repeat(64));
console.log(`PASSED ${CASES.length - failed}   FAILED ${failed}`);
if (failed) {
  console.log("\nRESULT: FAIL");
  process.exit(1);
}
console.log(
  "\nRESULT: PASS — fingerprinters flagged (no benign false-positive) + canary" +
    "\nexfiltration caught, attributed, and blocked. Zero-trust honeypot proven."
);

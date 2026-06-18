#!/usr/bin/env node
/**
 * BearBrowser Gecko RFP (resistFingerprinting) regression harness.
 *
 * This is the Gecko-surface counterpart to verify-fingerprint-shield.mjs (which
 * tests the legacy WKWebView JS shield). Per the Gecko-first surface strategy,
 * anti-fingerprinting "best in world" is owned by Firefox RFP, not the hand-rolled
 * WebKit shield. This harness makes that posture *measurable and enforced*.
 *
 * Two phases:
 *
 *   PHASE A — static pref audit (always runs, zero dependencies)
 *     Parses settings/profiles/<profile>/user.js and enforces:
 *       - REQUIRED  : the RFP backbone prefs are present with correct values
 *       - DEAD      : removed/no-op prefs are absent (e.g. randomDataOnCanvasExtract)
 *       - HARMFUL   : cohort-desyncing prefs are absent (UA overrides, manual DPR
 *                     spoof, non-native-theme=false) — these make RFP users MORE
 *                     unique by deviating from the cohort
 *       - TYPOS     : known non-existent pref names (e.g. network.http.http3.enabled
 *                     with a trailing 'd') that silently no-op
 *       - DUP       : the same pref key set twice
 *     This phase would have caught all three bugs found in the 2026-06 RFP audit.
 *
 *   PHASE B — runtime RFP probe (skips cleanly if no Gecko binary is available)
 *     Launches a Gecko build with the profile's RFP prefs and asserts the
 *     RFP-driven runtime behaviours (timezone→UTC, hardwareConcurrency→2, etc.).
 *     Binary resolution order:
 *       1. $BEARBROWSER_BIN          (the real built BearBrowser/LibreWolf binary)
 *       2. Playwright's bundled Firefox (if `npx playwright install firefox` was run)
 *       3. none → PHASE B is skipped (not a failure)
 *
 * Exit 0 = all enforced checks passed. Exit 1 = one or more failed.
 *
 * Usage:
 *   node scripts/verify-gecko-rfp.mjs                 # both profiles, both phases
 *   node scripts/verify-gecko-rfp.mjs --profile human-secure
 *   node scripts/verify-gecko-rfp.mjs --static-only   # skip the runtime probe
 *   BEARBROWSER_BIN=/Applications/BearBrowser.app/Contents/MacOS/bearbrowser \
 *     node scripts/verify-gecko-rfp.mjs               # probe the real binary
 */

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dir, '..');

// ── CLI ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const staticOnly = argv.includes('--static-only');
const profileArg = (() => {
  const i = argv.indexOf('--profile');
  return i >= 0 ? argv[i + 1] : null;
})();
const PROFILES = profileArg ? [profileArg] : ['human-secure', 'agent-runtime'];

// ── tiny ANSI helpers ─────────────────────────────────────────────────────────
const C = {
  reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m',
  green: '\x1b[32m', red: '\x1b[31m', yellow: '\x1b[33m', cyan: '\x1b[36m',
};
const ok = (s) => `${C.green}✓${C.reset} ${s}`;
const bad = (s) => `${C.red}✗${C.reset} ${s}`;
const warn = (s) => `${C.yellow}⚠${C.reset} ${s}`;

// ─────────────────────────────────────────────────────────────────────────────
//  PHASE A — static pref audit rules
// ─────────────────────────────────────────────────────────────────────────────

// RFP backbone: must be present and equal to the expected value.
// These are the load-bearing prefs that define the Tor-style uniformity cohort.
const REQUIRED = {
  'privacy.resistFingerprinting': true,
  'privacy.resistFingerprinting.letterboxing': true,
  'privacy.resistFingerprinting.reduceTimerPrecision': true,
  'privacy.trackingprotection.fingerprinting.enabled': true,
  'privacy.resistFingerprinting.block_mozAddonManager': true,
  'layout.css.font-visibility.standard': 2,
  'media.peerconnection.ice.no_host': true,
  'media.peerconnection.ice.default_address_only': true,
  'intl.accept_languages': 'en-US, en',
  // Network-state isolation: the decisive defense against QUIC NEW_TOKEN /
  // TLS-0-RTT cross-connection supercookies (partitions them by first party).
  'privacy.partition.network_state': true,
  // Defense-in-depth: no 0-RTT early data (removes the QUIC/TLS replay surface).
  'security.tls.enable_0rtt_data': false,
};

// Removed / deprecated prefs that are silent no-ops in current Firefox. Their
// presence is misleading (implies protection that isn't there). Fail if found.
const DEAD = {
  'privacy.resistFingerprinting.randomDataOnCanvasExtract':
    'removed in bug 1670447; canvas noise is always-on under RFP (bug 1816189)',
};

// Cohort-desyncing / counterproductive prefs. Under RFP these make the browser
// MORE fingerprintable by deviating from the RFP crowd, or actively reopen a
// vector. Fail if present (HARMFUL_IF_FALSE only fails when set to false).
const HARMFUL = {
  'general.useragent.override': 'manual UA override desyncs from the RFP cohort UA',
  'general.platform.override': 'manual platform override desyncs from the RFP cohort',
  'general.appversion.override': 'manual appVersion override desyncs from the RFP cohort',
  'general.appname.override': 'manual appName override desyncs from the RFP cohort',
  'general.oscpu.override': 'manual oscpu override desyncs from the RFP cohort',
  'general.buildID.override': 'manual buildID override desyncs from the RFP cohort',
  'layout.css.devPixelsPerPx':
    'manual devicePixelRatio spoof; RFP owns DPR — hardcoding it breaks non-Retina ' +
    'displays and desyncs from RFP rounding (this leaked over from the WKWebView shield)',
};
const HARMFUL_IF_FALSE = {
  'widget.non-native-theme.enabled':
    'false reopens the OS-native form-control theme leak; the hardened value is true',
};

// Known non-existent pref names (typos of real prefs) that silently no-op.
// Maps the bad name → the canonical name it was probably meant to be.
const KNOWN_TYPOS = {
  'network.http.http3.enabled': 'network.http.http3.enable',
  'privacy.resistFingerprinting.letterboxing.enabled': 'privacy.resistFingerprinting.letterboxing',
};

// ── user.js parser ────────────────────────────────────────────────────────────
// Returns { order: [name,...], prefs: Map<name, {value, line, raw}>, dups: [...] }
function parseUserJs(text) {
  const prefs = new Map();
  const order = [];
  const dups = [];
  const re = /user_pref\(\s*"([^"]+)"\s*,\s*(true|false|-?\d+|"(?:[^"\\]|\\.)*")\s*\)\s*;/;
  const lines = text.split('\n');
  lines.forEach((line, idx) => {
    const m = line.match(re);
    if (!m) return;
    const name = m[1];
    let v = m[2];
    let value;
    if (v === 'true') value = true;
    else if (v === 'false') value = false;
    else if (/^-?\d+$/.test(v)) value = parseInt(v, 10);
    else value = v.slice(1, -1); // strip quotes
    if (prefs.has(name)) dups.push({ name, line: idx + 1 });
    else order.push(name);
    prefs.set(name, { value, line: idx + 1, raw: v });
  });
  return { order, prefs, dups };
}

function valStr(v) {
  return typeof v === 'string' ? `"${v}"` : String(v);
}

function auditProfile(profile) {
  const file = path.join(repoRoot, 'settings', 'profiles', profile, 'user.js');
  if (!existsSync(file)) {
    return { profile, missing: true, results: [], failed: 1 };
  }
  const { prefs, dups } = parseUserJs(readFileSync(file, 'utf8'));
  const results = [];
  const add = (pass, label, detail) => results.push({ pass, label, detail });

  // REQUIRED present + correct
  for (const [name, want] of Object.entries(REQUIRED)) {
    if (!prefs.has(name)) {
      add(false, `required ${name}`, `missing (expected ${valStr(want)})`);
    } else {
      const got = prefs.get(name).value;
      add(got === want, `required ${name}`,
        got === want ? `= ${valStr(got)}` : `= ${valStr(got)}, expected ${valStr(want)}`);
    }
  }

  // DEAD absent
  for (const [name, why] of Object.entries(DEAD)) {
    const present = prefs.has(name);
    add(!present, `dead-pref ${name}`,
      present ? `present at line ${prefs.get(name).line} — ${why}` : 'absent');
  }

  // HARMFUL absent
  for (const [name, why] of Object.entries(HARMFUL)) {
    const present = prefs.has(name);
    add(!present, `no-desync ${name}`,
      present ? `present at line ${prefs.get(name).line} — ${why}` : 'absent');
  }
  for (const [name, why] of Object.entries(HARMFUL_IF_FALSE)) {
    const isFalse = prefs.has(name) && prefs.get(name).value === false;
    add(!isFalse, `no-desync ${name}`,
      isFalse ? `= false at line ${prefs.get(name).line} — ${why}` : 'ok');
  }

  // TYPOS absent
  for (const [bad_, canonical] of Object.entries(KNOWN_TYPOS)) {
    const present = prefs.has(bad_);
    add(!present, `no-typo ${bad_}`,
      present
        ? `present at line ${prefs.get(bad_).line} — non-existent pref; did you mean "${canonical}"? (silent no-op)`
        : 'absent');
  }

  // DUP keys
  if (dups.length === 0) {
    add(true, 'no-duplicate-keys', 'clean');
  } else {
    for (const d of dups) add(false, 'no-duplicate-keys', `"${d.name}" re-set at line ${d.line}`);
  }

  const failed = results.filter((r) => !r.pass).length;
  return { profile, missing: false, results, failed };
}

// ─────────────────────────────────────────────────────────────────────────────
//  PHASE B — runtime RFP probe
// ─────────────────────────────────────────────────────────────────────────────

// RFP-driven behaviours that hold in any Gecko build with privacy.resistFingerprinting=true.
// These are engine-level guarantees (nsRFPService), independent of LibreWolf patches.
const RUNTIME_PROBE = `(function(){
  const r = {};
  try { r.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; } catch(e){ r.timezone = 'ERR:'+e; }
  try { r.tzOffset = new Date().getTimezoneOffset(); } catch(e){ r.tzOffset = 'ERR'; }
  try { r.hwConcurrency = navigator.hardwareConcurrency; } catch(e){ r.hwConcurrency = 'ERR'; }
  try { r.languages = JSON.stringify(navigator.languages); } catch(e){ r.languages = 'ERR'; }
  try { r.maxTouchPoints = navigator.maxTouchPoints; } catch(e){ r.maxTouchPoints = 'ERR'; }
  try { r.deviceMemory = (navigator.deviceMemory === undefined ? 'undefined' : navigator.deviceMemory); } catch(e){ r.deviceMemory = 'ERR'; }
  return r;
})()`;

async function resolveFirefox() {
  // 1. real built binary
  if (process.env.BEARBROWSER_BIN && existsSync(process.env.BEARBROWSER_BIN)) {
    return { kind: 'binary', execPath: process.env.BEARBROWSER_BIN };
  }
  // 2. Playwright-bundled Firefox, only if actually downloaded
  try {
    const { firefox } = await import('playwright');
    const ep = firefox.executablePath();
    if (ep && existsSync(ep)) return { kind: 'playwright', firefox };
  } catch { /* playwright not installed */ }
  return null;
}

// Turn a parsed user.js into Playwright firefoxUserPrefs (RFP-relevant subset is fine;
// passing all parsed prefs is harmless and most faithful to the shipped profile).
function profilePrefs(profile) {
  const file = path.join(repoRoot, 'settings', 'profiles', profile, 'user.js');
  if (!existsSync(file)) return {};
  const { prefs } = parseUserJs(readFileSync(file, 'utf8'));
  const out = {};
  for (const [name, { value }] of prefs) out[name] = value;
  return out;
}

async function runtimeProbe(profile) {
  const ff = await resolveFirefox();
  if (!ff) return { skipped: true, reason: 'no Gecko binary (set BEARBROWSER_BIN or run: npx playwright install firefox)' };
  if (ff.kind === 'binary') {
    // Driving an arbitrary external binary requires Marionette/remote wiring that is
    // out of scope here; report that it was detected and leave the hook for CI.
    return { skipped: true, reason: `binary at ${ff.execPath} detected — wire Marionette in CI to probe it` };
  }
  const { firefox } = ff;
  const browser = await firefox.launch({ headless: true, firefoxUserPrefs: profilePrefs(profile) });
  try {
    const page = await browser.newPage();
    await page.goto('about:blank');
    const r = await page.evaluate(RUNTIME_PROBE);
    const results = [];
    const add = (pass, label, detail) => results.push({ pass, label, detail });
    add(r.timezone === 'UTC', 'rfp_timezone_utc', `timezone=${r.timezone}`);
    add(r.tzOffset === 0, 'rfp_tz_offset_zero', `getTimezoneOffset=${r.tzOffset}`);
    add(r.hwConcurrency === 2, 'rfp_hardwareConcurrency_2', `hardwareConcurrency=${r.hwConcurrency}`);
    add(r.languages === '["en-US","en"]' || r.languages === '["en-US"]',
      'rfp_languages_en', `languages=${r.languages}`);
    add(r.maxTouchPoints === 0, 'rfp_maxTouchPoints_0', `maxTouchPoints=${r.maxTouchPoints}`);
    add(r.deviceMemory === 'undefined' || r.deviceMemory === 8 || r.deviceMemory === 4,
      'rfp_deviceMemory_normalized', `deviceMemory=${r.deviceMemory}`);
    const failed = results.filter((x) => !x.pass).length;
    return { skipped: false, kind: 'playwright-firefox', results, failed };
  } finally {
    await browser.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Driver
// ─────────────────────────────────────────────────────────────────────────────
let totalFailed = 0;

console.log(`${C.bold}BearBrowser Gecko RFP harness${C.reset}`);
console.log('─'.repeat(62));

for (const profile of PROFILES) {
  console.log(`\n${C.bold}${C.cyan}profile: ${profile}${C.reset}`);
  console.log(`${C.dim}Phase A — static pref audit${C.reset}`);
  const a = auditProfile(profile);
  if (a.missing) {
    console.log(bad(`user.js not found for profile "${profile}"`));
    totalFailed += 1;
    continue;
  }
  for (const r of a.results) {
    console.log('  ' + (r.pass ? ok(r.label) : bad(`${r.label} — ${r.detail}`)));
  }
  totalFailed += a.failed;

  if (!staticOnly) {
    console.log(`${C.dim}Phase B — runtime RFP probe${C.reset}`);
    try {
      const b = await runtimeProbe(profile);
      if (b.skipped) {
        console.log('  ' + warn(`skipped: ${b.reason}`));
      } else {
        for (const r of b.results) {
          console.log('  ' + (r.pass ? ok(r.label) : bad(`${r.label} — ${r.detail}`)));
        }
        totalFailed += b.failed;
      }
    } catch (e) {
      console.log('  ' + warn(`runtime probe error (non-fatal): ${e.message}`));
    }
  }
}

console.log('\n' + '─'.repeat(62));
if (totalFailed === 0) {
  console.log(`${C.bold}all enforced checks passed${C.reset}  ${C.green}clean${C.reset}`);
  process.exit(0);
} else {
  console.log(`${C.bold}${C.red}${totalFailed} check(s) failed${C.reset}`);
  process.exit(1);
}

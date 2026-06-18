#!/usr/bin/env node
/**
 * BearBrowser empirical fingerprint measurement (T0 — "prove it").
 *
 * The verify-gecko-rfp.mjs harness proves the CONFIG is correct (static) and that
 * a handful of RFP behaviours hold (Phase B). This script answers the harder
 * question — "how identifiable are we, actually?" — by launching a real Gecko
 * engine THREE times and measuring the full fingerprint surface the real
 * adversarial suites (EFF Cover Your Tracks, creepjs, fingerprintjs) hash:
 *
 *   control  = bare Firefox, NO hardening          (the entropy we start with)
 *   hardened = Firefox + our profile's RFP prefs   (session 1)
 *   hardened2= Firefox + our profile's RFP prefs   (session 2, fresh launch)
 *
 * For each vector we classify the result:
 *   NORMALIZED        — hardened value is a fixed cohort value, != control
 *   RANDOMIZED        — hardened != control AND hardened != hardened2
 *                       (per-session noise → unlinkable across sessions; ideal
 *                        for canvas/audio)
 *   LEAKING           — hardened == control (real device value still exposed)
 *   MATCHES-COHORT    — already at the expected RFP cohort value
 *
 * Output: a per-vector table + a headline "neutralized N / M high-entropy
 * vectors" score. This is the number to optimize for "best in world".
 *
 * NOTE: this uses Playwright's bundled Firefox (real Gecko + RFP), not the final
 * LibreWolf/BearBrowser binary. RFP is upstream Gecko so results transfer, but
 * the exact build may differ slightly (flagged where it matters). Point at the
 * real binary later via BEARBROWSER_BIN once a build exists.
 *
 * Usage:
 *   node scripts/measure-fingerprint.mjs                 # human-secure
 *   node scripts/measure-fingerprint.mjs --profile agent-runtime
 *   node scripts/measure-fingerprint.mjs --json          # machine-readable
 */

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dir, '..');
const argv = process.argv.slice(2);
const jsonOut = argv.includes('--json');
const profile = (() => { const i = argv.indexOf('--profile'); return i >= 0 ? argv[i + 1] : 'human-secure'; })();

const C = { reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m', green: '\x1b[32m', red: '\x1b[31m', amber: '\x1b[33m', cyan: '\x1b[36m' };

// ── parse a profile's user.js into Playwright firefoxUserPrefs ───────────────
function profilePrefs(prof) {
  const file = path.join(repoRoot, 'settings', 'profiles', prof, 'user.js');
  const out = {};
  if (!existsSync(file)) return out;
  const re = /user_pref\(\s*"([^"]+)"\s*,\s*(true|false|-?\d+|"(?:[^"\\]|\\.)*")\s*\)/;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(re);
    if (!m) continue;
    let v = m[2];
    if (v === 'true') v = true;
    else if (v === 'false') v = false;
    else if (/^-?\d+$/.test(v)) v = parseInt(v, 10);
    else v = v.slice(1, -1);
    out[m[1]] = v;
  }
  return out;
}

// ── the in-page probe — collects the entropy-bearing surface ─────────────────
const PROBE = `async () => {
  const r = {};
  const nav = navigator;
  r.userAgent = nav.userAgent;
  r.platform = nav.platform;
  r.hardwareConcurrency = nav.hardwareConcurrency;
  r.deviceMemory = (nav.deviceMemory === undefined ? 'undefined' : nav.deviceMemory);
  r.languages = (nav.languages || []).join(',');
  r.maxTouchPoints = nav.maxTouchPoints;
  r.vendor = nav.vendor;
  r.oscpu = (nav.oscpu === undefined ? 'undefined' : nav.oscpu);
  r.plugins = nav.plugins ? nav.plugins.length : 0;
  r.connection = nav.connection ? (nav.connection.effectiveType || 'present') : 'absent';
  r.screen = screen.width + 'x' + screen.height;
  r.avail = screen.availWidth + 'x' + screen.availHeight;
  r.colorDepth = screen.colorDepth;
  r.dpr = window.devicePixelRatio;
  r.innerWH = window.innerWidth + 'x' + window.innerHeight;
  r.outerWH = window.outerWidth + 'x' + window.outerHeight;
  r.orientation = (screen.orientation || {}).type || 'none';
  try { r.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; } catch(e) { r.timezone = 'ERR'; }
  r.tzOffset = new Date().getTimezoneOffset();
  try { r.locale = Intl.DateTimeFormat().resolvedOptions().locale; } catch(e) { r.locale = 'ERR'; }
  r.prefersDark = matchMedia('(prefers-color-scheme: dark)').matches;
  r.prefersReducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  r.pointerCoarse = matchMedia('(pointer: coarse)').matches;
  // canvas 2D
  try {
    const c = document.createElement('canvas'); c.width = 240; c.height = 60;
    const x = c.getContext('2d');
    x.textBaseline = 'top'; x.font = '14px Arial';
    x.fillStyle = '#f60'; x.fillRect(0, 0, 100, 30);
    x.fillStyle = '#069'; x.fillText('BearBrowser fp 9.9.9.9', 2, 15);
    x.fillStyle = 'rgba(102,200,0,0.7)'; x.fillText('BearBrowser fp', 4, 25);
    const d = c.toDataURL();
    let h = 5381; for (let i = 0; i < d.length; i++) h = ((h * 33) ^ d.charCodeAt(i)) >>> 0;
    r.canvasHash = h.toString(16);
  } catch(e) { r.canvasHash = 'ERR'; }
  // WebGL
  try {
    const gl = document.createElement('canvas').getContext('webgl');
    if (gl) {
      r.webglVendor = gl.getParameter(gl.VENDOR);
      r.webglRenderer = gl.getParameter(gl.RENDERER);
      const dbg = gl.getExtension('WEBGL_debug_renderer_info');
      r.webglUnmaskedRenderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : 'no-ext';
      r.webglExtCount = (gl.getSupportedExtensions() || []).length;
    } else { r.webglRenderer = 'no-webgl'; r.webglUnmaskedRenderer = 'no-webgl'; }
  } catch(e) { r.webglRenderer = 'ERR'; }
  // audio (OfflineAudioContext — the dominant audio fingerprint path)
  try {
    const ac = new OfflineAudioContext(1, 44100, 44100);
    const osc = ac.createOscillator(); osc.type = 'triangle'; osc.frequency.value = 10000;
    const comp = ac.createDynamicsCompressor();
    osc.connect(comp); comp.connect(ac.destination); osc.start(0);
    const buf = await ac.startRendering();
    const data = buf.getChannelData(0);
    let sum = 0; for (let i = 4000; i < 5000; i++) sum += Math.abs(data[i]);
    r.audioHash = sum.toFixed(8);
  } catch(e) { r.audioHash = 'ERR'; }
  // font enumeration via measureText width deltas
  try {
    const probe = 'mmmmmmmmmmlli', base = 'monospace';
    const cx = document.createElement('canvas').getContext('2d');
    const w = (f) => { cx.font = '72px ' + f; return cx.measureText(probe).width; };
    const baseW = w(base);
    // Mac-specific NON-web-safe fonts: present on stock macOS but NOT in the
    // cross-platform base set. font-visibility=2 should make these undetectable.
    // If they're detectable, the OS/installed-font fingerprint is leaking.
    const fonts = ['Zapfino','Papyrus','Herculanum','Apple Chancery','Hoefler Text','Optima','Skia','Chalkduster','Marker Felt','Noteworthy','Phosphate','Trattatello','Luminari','Bodoni 72'];
    let det = 0; for (const f of fonts) if (w("'" + f + "'," + base) !== baseW) det++;
    r.fontsDetected = det + '/' + fonts.length;
  } catch(e) { r.fontsDetected = 'ERR'; }
  // Text-metric / kerning readback. A page can read the exact advance width and
  // sub-pixel bounding box, which encodes font + shaper + rasterizer = high entropy.
  // 'int' = quantized (uniform); 'subpixel' = the raw transform is exposed (leak).
  try {
    const tcx = document.createElement('canvas').getContext('2d');
    tcx.font = '32px sans-serif';
    const tm = tcx.measureText('AVA To Wa Yo PAW fjffifl 9.9.9.9');
    r.textWidth = tm.width;
    r.textMetrics = (Math.abs(tm.width - Math.round(tm.width)) < 1e-6) ? 'int' : 'subpixel';
  } catch(e) { r.textMetrics = 'ERR'; }
  // WebRTC ICE local-IP leak. mDNS (*.local) candidates are obfuscated and not a
  // real IP leak; only a raw private/public IP counts. 'clean' = no raw IP exposed.
  r.webrtcLeak = await new Promise((resolve) => {
    let pc;
    try { pc = new RTCPeerConnection({ iceServers: [] }); } catch(e) { return resolve('clean'); }
    if (!pc || !pc.createDataChannel) return resolve('clean');
    const ips = new Set(); let done = false;
    const finish = () => { if (!done) { done = true; resolve(ips.size ? 'LEAK:' + [...ips].join(',') : 'clean'); } };
    try { pc.createDataChannel('x'); } catch(e) {}
    pc.onicecandidate = (e) => {
      if (!e.candidate) return finish();
      const cand = e.candidate.candidate || '';
      if (cand.includes('.local')) return;
      const m = cand.match(/(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/);
      if (m) ips.add(m[0]);
    };
    pc.createOffer().then((o) => pc.setLocalDescription(o)).catch(() => {});
    setTimeout(finish, 2500);
  });
  return r;
}`;

async function collect(prefs) {
  const { firefox } = await import('playwright');
  const browser = await firefox.launch({ headless: true, firefoxUserPrefs: prefs });
  try {
    const page = await browser.newPage();
    await page.goto('about:blank');
    return await page.evaluate(eval('(' + PROBE + ')'));
  } finally {
    await browser.close();
  }
}

// ── high-entropy vectors and how to judge each ───────────────────────────────
// kind: 'mask' = should differ from control & be a fixed cohort value;
//       'noise' = should differ from control AND vary across sessions;
//       'fixed' = should equal an expected cohort value.
const VECTORS = [
  // cohort: a matcher; if the hardened value matches, it's a uniform RFP cohort
  // value (good) even when identical to control — NOT a device leak.
  { key: 'userAgent', label: 'User-Agent', kind: 'mask', cohort: (a) => /Mac OS X 10\.15;.*Firefox\/\d+\.0$/.test(a) },
  { key: 'platform', label: 'navigator.platform', kind: 'mask', cohort: (a) => a === 'MacIntel' },
  { key: 'hardwareConcurrency', label: 'hardwareConcurrency', kind: 'fixed', expect: 2 },
  { key: 'deviceMemory', label: 'deviceMemory', kind: 'fixed', expect: 'undefined' },
  { key: 'maxTouchPoints', label: 'maxTouchPoints', kind: 'fixed', expect: 0 },
  { key: 'connection', label: 'navigator.connection', kind: 'fixed', expect: 'absent' },
  { key: 'screen', label: 'screen WxH', kind: 'mask' },
  { key: 'dpr', label: 'devicePixelRatio', kind: 'mask' },
  { key: 'tzOffset', label: 'timezone offset', kind: 'fixed', expect: 0 },
  { key: 'locale', label: 'Intl locale', kind: 'fixed', expect: 'en-US' },
  { key: 'prefersDark', label: 'prefers dark', kind: 'fixed', expect: false },
  { key: 'canvasHash', label: 'canvas 2D', kind: 'noise' },
  { key: 'audioHash', label: 'audio (oac)', kind: 'noise' },
  { key: 'webglUnmaskedRenderer', label: 'WebGL renderer', kind: 'mask' },
  { key: 'webglExtCount', label: 'WebGL ext count', kind: 'mask' },
  { key: 'fontsDetected', label: 'non-base fonts', kind: 'fixed', expect: '0/14' },
  { key: 'textMetrics', label: 'text-metric readback', kind: 'fixed', expect: 'int' },
  { key: 'plugins', label: 'plugins', kind: 'mask', cohort: (a) => a === 0 },
  { key: 'webrtcLeak', label: 'WebRTC IP leak', kind: 'fixed', expect: 'clean' },
];

function classify(v, control, h1, h2) {
  const c = control[v.key], a = h1[v.key], b = h2[v.key];
  if (v.kind === 'fixed') {
    if (a === v.expect) return a === c ? 'MATCHES-COHORT' : 'NORMALIZED';
    return 'LEAKING';
  }
  if (v.kind === 'noise') {
    if (a === c) return 'LEAKING';
    return a !== b ? 'RANDOMIZED' : 'STATIC-SPOOF';
  }
  // mask
  if (v.cohort && v.cohort(a)) return 'MATCHES-COHORT';
  if (a === c) return 'LEAKING';
  return 'NORMALIZED';
}

const GOOD = new Set(['NORMALIZED', 'RANDOMIZED', 'MATCHES-COHORT']);

(async () => {
  const prefs = profilePrefs(profile);
  process.stderr.write(`launching Gecko x3 (control + ${profile} x2)...\n`);
  const control = await collect({});
  const h1 = await collect(prefs);
  const h2 = await collect(prefs);

  const rows = VECTORS.map((v) => {
    const status = classify(v, control, h1, h2);
    return { vector: v.label, kind: v.kind, control: String(control[v.key]).slice(0, 30), hardened: String(h1[v.key]).slice(0, 30), status };
  });
  const neutralized = rows.filter((r) => GOOD.has(r.status)).length;

  if (jsonOut) {
    console.log(JSON.stringify({ profile, neutralized, total: rows.length, control, h1, h2, rows }, null, 2));
    return;
  }

  const col = (s) => GOOD.has(s) ? `${C.green}${s}${C.reset}` : (s === 'LEAKING' ? `${C.red}${s}${C.reset}` : `${C.amber}${s}${C.reset}`);
  console.log(`\n${C.bold}BearBrowser fingerprint measurement — ${profile}${C.reset}`);
  console.log(`${C.dim}control = bare Gecko · hardened = + RFP profile${C.reset}`);
  console.log('─'.repeat(78));
  console.log(`${C.dim}${'vector'.padEnd(22)}${'control'.padEnd(26)}${'hardened'.padEnd(18)}status${C.reset}`);
  for (const r of rows) {
    console.log(`${r.vector.padEnd(22)}${C.dim}${r.control.padEnd(26)}${C.reset}${r.hardened.padEnd(18)}${col(r.status)}`);
  }
  console.log('─'.repeat(78));
  const pct = Math.round((neutralized / rows.length) * 100);
  const color = pct === 100 ? C.green : pct >= 80 ? C.amber : C.red;
  console.log(`${C.bold}neutralized ${color}${neutralized}/${rows.length}${C.reset}${C.bold} high-entropy vectors (${pct}%)${C.reset}`);
  const leaks = rows.filter((r) => r.status === 'LEAKING');
  if (leaks.length) console.log(`${C.red}leaking:${C.reset} ${leaks.map((r) => r.vector).join(', ')}`);
})();

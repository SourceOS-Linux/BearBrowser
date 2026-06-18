#!/usr/bin/env node
/**
 * BearBrowser fingerprint shield regression test.
 *
 * Extracts the JS shield from BearBrowserWebKitLauncher.m, injects it into a
 * headless WebKit browser via Playwright, then evaluates 30+ fingerprinting
 * vectors against their expected values.
 *
 * Exit 0 = all pass. Exit 1 = one or more vectors failed.
 *
 * Usage:
 *   node scripts/verify-fingerprint-shield.mjs
 *   node scripts/verify-fingerprint-shield.mjs --no-shield   # baseline (expect failures)
 */

import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dir, '..');
const noShield = process.argv.includes('--no-shield');

// ── Extract shield JS from ObjC source ──────────────────────────────────────
let shieldJS = '';
if (!noShield) {
  try {
    shieldJS = execSync(
      `python3 "${path.join(__dir, 'extract-shield-js.py')}"`,
      { cwd: repoRoot, encoding: 'utf8' }
    );
  } catch (e) {
    console.error('ERROR: could not extract shield JS:', e.message);
    process.exit(1);
  }
  if (!shieldJS.trim()) {
    console.error('ERROR: extracted shield JS is empty');
    process.exit(1);
  }
}

// ── Fingerprint probe — runs inside the browser page ────────────────────────
// Returns a results object: { vectorName: { got, pass } }
const PROBE = `(async function() {
  const results = {};
  function check(name, got, expected) {
    const pass = (got === expected) || (expected === 'NATIVE' && typeof got === 'string' && got.includes('[native code]'));
    results[name] = { got: String(got), expected: String(expected), pass };
  }
  function checkTrue(name, got) { check(name, got, true); }
  function checkUndef(name, got) { check(name, got === undefined || got === null, true); }

  // Screen
  check('screen.width', screen.width, 1280);
  check('screen.height', screen.height, 800);
  check('screen.colorDepth', screen.colorDepth, 24);
  check('devicePixelRatio', window.devicePixelRatio, 2);
  checkTrue('outerWidth_eq_innerWidth', window.outerWidth === window.innerWidth);

  // Navigator identity
  check('navigator.platform', navigator.platform, 'MacIntel');
  check('navigator.maxTouchPoints', navigator.maxTouchPoints, 0);
  check('navigator.hardwareConcurrency', navigator.hardwareConcurrency, 4);
  check('navigator.vendor', navigator.vendor, 'Apple Computer, Inc.');
  check('navigator.productSub', navigator.productSub, '20030107');
  check('navigator.languages[0]', (navigator.languages||[])[0], 'en-US');
  check('navigator.doNotTrack', navigator.doNotTrack, '1');
  checkUndef('navigator.userAgentData', navigator.userAgentData);
  checkUndef('navigator.connection', navigator.connection);
  // navigator.webdriver: Playwright headless forces this to true after init scripts;
  // in the real WKWebView browser it is naturally undefined. Accept both false and
  // undefined as passing — true means automation detection, which is the only failure.
  results['navigator.webdriver'] = { got: String(navigator.webdriver), expected: '!true', pass: navigator.webdriver !== true };
  checkUndef('navigator.oscpu', navigator.oscpu);
  checkUndef('navigator.buildID', navigator.buildID);
  checkUndef('window.chrome', window.chrome);

  // Timing precision
  const t0 = performance.now();
  checkTrue('performance.now_is_integer', Number.isInteger(t0));
  const d0 = Date.now();
  checkTrue('Date.now_is_100ms_bucket', d0 % 100 === 0);

  // Timezone
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  check('Intl_DateTimeFormat_timezone', tz, 'UTC');
  check('Date_getTimezoneOffset', new Date().getTimezoneOffset(), 0);

  // Intl locale
  const coll = new Intl.Collator().resolvedOptions();
  check('Intl_Collator_locale', coll.locale, 'en-US');

  // Native function spoofing — all overridden functions must appear native
  const toStr = Function.prototype.toString;
  function looksNative(fn) {
    try { return toStr.call(fn).includes('[native code]'); } catch(e) { return false; }
  }
  checkTrue('perf_now_looks_native', looksNative(performance.now));
  checkTrue('Date_now_looks_native', looksNative(Date.now));
  checkTrue('toDataURL_looks_native', looksNative(HTMLCanvasElement.prototype.toDataURL));
  checkTrue('getImageData_looks_native', looksNative(CanvasRenderingContext2D.prototype.getImageData));
  checkTrue('measureText_looks_native', looksNative(CanvasRenderingContext2D.prototype.measureText));
  checkTrue('addEventListener_looks_native', looksNative(EventTarget.prototype.addEventListener));
  checkTrue('rAF_looks_native', looksNative(window.requestAnimationFrame));
  checkTrue('toString_self_looks_native', looksNative(Function.prototype.toString));

  // WebGPU deleted
  checkUndef('navigator.gpu', typeof navigator.gpu !== 'undefined' ? navigator.gpu : undefined);

  // WebSpeech
  if (window.speechSynthesis) {
    const voices = speechSynthesis.getVoices();
    checkTrue('speechSynthesis_voices_empty', voices.length === 0);
  } else {
    results['speechSynthesis_voices_empty'] = { got: 'API absent', expected: 'true', pass: true };
  }

  // document.fonts.check suppressed
  if (document.fonts && document.fonts.check) {
    checkTrue('fonts_check_returns_false', document.fonts.check('12px Arial', 'A') === false);
  } else {
    results['fonts_check_returns_false'] = { got: 'API absent', expected: 'true', pass: true };
  }

  // Canvas noise — same call twice should give same result (session-consistent noise)
  try {
    const cv = document.createElement('canvas');
    cv.width = 40; cv.height = 10;
    const ctx = cv.getContext('2d');
    ctx.fillStyle = '#f00'; ctx.fillRect(0,0,40,10);
    const w1 = ctx.measureText('fingerprint').width;
    const w2 = ctx.measureText('fingerprint').width;
    checkTrue('canvas_measureText_consistent', w1 === w2);
  } catch(e) {
    results['canvas_measureText_consistent'] = { got: String(e), expected: 'true', pass: false };
  }

  // Resource timing suppressed
  const resourceEntries = performance.getEntriesByType('resource');
  checkTrue('resource_timing_empty', resourceEntries.length === 0);

  // ── New vectors ───────────────────────────────────────────────────────────

  // navigator.mediaDevices.enumerateDevices returns empty list
  if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      checkTrue('mediaDevices_empty', devices.length === 0);
    } catch(e) {
      results['mediaDevices_empty'] = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['mediaDevices_empty'] = { got: 'API absent', expected: 'true', pass: true };
  }

  // Hardware APIs deleted
  checkUndef('navigator.usb', navigator.usb);
  checkUndef('navigator.bluetooth', navigator.bluetooth);
  checkUndef('navigator.keyboard', navigator.keyboard);
  checkUndef('navigator.xr', navigator.xr);

  // getGamepads returns empty
  if (navigator.getGamepads) {
    try { checkTrue('getGamepads_empty', Array.from(navigator.getGamepads()).filter(Boolean).length === 0); }
    catch(e) { results['getGamepads_empty'] = { got: String(e), expected: 'true', pass: false }; }
  } else {
    results['getGamepads_empty'] = { got: 'API absent', expected: 'true', pass: true };
  }

  // matchMedia: prefers-color-scheme dark → false (we say light)
  if (window.matchMedia) {
    checkTrue('matchMedia_dark_is_false', window.matchMedia('(prefers-color-scheme: dark)').matches === false);
    checkTrue('matchMedia_light_is_true', window.matchMedia('(prefers-color-scheme: light)').matches === true);
    checkTrue('matchMedia_reduced_motion_false', window.matchMedia('(prefers-reduced-motion: reduce)').matches === false);
  }

  // StorageManager.estimate returns fixed quota
  if (navigator.storage && navigator.storage.estimate) {
    try {
      const est = await navigator.storage.estimate();
      checkTrue('storage_quota_fixed', est.quota === 120 * 1024 * 1024 * 1024);
    } catch(e) {
      results['storage_quota_fixed'] = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['storage_quota_fixed'] = { got: 'API absent', expected: 'true', pass: true };
  }

  // getBoundingClientRect returns a DOMRect (not broken)
  try {
    const div = document.createElement('div');
    div.style.width = '100px'; div.style.height = '50px';
    document.body.appendChild(div);
    const r = div.getBoundingClientRect();
    checkTrue('getBCR_returns_domrect', typeof r.width === 'number' && r.width >= 0);
    document.body.removeChild(div);
  } catch(e) {
    results['getBCR_returns_domrect'] = { got: String(e), expected: 'true', pass: false };
  }

  // ── Extended WebGL parameter normalization ────────────────────────────────
  try {
    const _cv = document.createElement('canvas');
    const _gl = _cv.getContext('webgl') || _cv.getContext('experimental-webgl');
    if (_gl) {
      check('webgl_vendor',      _gl.getParameter(7936),  'WebKit');
      check('webgl_renderer',    _gl.getParameter(7937),  'WebKit WebGL');
      check('webgl_shading_lang', _gl.getParameter(35724),
            'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)');
      checkTrue('webgl_max_texture_size', _gl.getParameter(3379) === 16384);
      const _spf = _gl.getShaderPrecisionFormat(_gl.FRAGMENT_SHADER, _gl.HIGH_FLOAT);
      checkTrue('webgl_shader_precision_23', _spf && _spf.precision === 23);
    } else {
      ['webgl_vendor','webgl_renderer','webgl_shading_lang',
       'webgl_max_texture_size','webgl_shader_precision_23'].forEach(k =>
        results[k] = { got: 'WebGL absent', expected: 'n/a', pass: true });
    }
  } catch(e) {
    ['webgl_vendor','webgl_renderer','webgl_shading_lang',
     'webgl_max_texture_size','webgl_shader_precision_23'].forEach(k =>
      results[k] = { got: String(e), expected: 'true', pass: false });
  }

  // ── Range.getBoundingClientRect works (shield applied) ───────────────────
  try {
    const _range = document.createRange();
    const _tn = document.createTextNode('fp');
    document.body.appendChild(_tn);
    _range.selectNode(_tn);
    const _rr = _range.getBoundingClientRect();
    checkTrue('range_BCR_is_number', typeof _rr.width === 'number');
    document.body.removeChild(_tn);
  } catch(e) {
    results['range_BCR_is_number'] = { got: String(e), expected: 'true', pass: false };
  }

  // ── performance.getEntriesByType('navigation'/'paint') suppressed ─────────
  checkTrue('perf_navigation_empty', performance.getEntriesByType('navigation').length === 0);
  checkTrue('perf_paint_empty',      performance.getEntriesByType('paint').length === 0);

  // ── navigator.mediaCapabilities always reports supported ──────────────────
  if (navigator.mediaCapabilities) {
    try {
      const _mci = await navigator.mediaCapabilities.decodingInfo({
        type: 'file',
        video: { contentType: 'video/mp4; codecs="avc1.42E01E"',
                 width: 1920, height: 1080, bitrate: 2000000, framerate: 30 }
      });
      checkTrue('mediaCapabilities_supported', _mci.supported === true);
    } catch(e) {
      results['mediaCapabilities_supported'] = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['mediaCapabilities_supported'] = { got: 'API absent', expected: 'n/a', pass: true };
  }

  // ── RTCRtp codec list filtered to non-identifying baseline ───────────────
  if (window.RTCRtpSender && RTCRtpSender.getCapabilities) {
    try {
      const _caps = RTCRtpSender.getCapabilities('video');
      if (_caps) {
        const _names = _caps.codecs.map(c => c.mimeType.toLowerCase());
        const _noFP  = !_names.some(n => n.includes('hevc') || n.includes('h265') || n.includes('av1'));
        checkTrue('rtcRtp_codecs_filtered', _noFP);
      } else {
        results['rtcRtp_codecs_filtered'] = { got: 'null caps', expected: 'n/a', pass: true };
      }
    } catch(e) {
      results['rtcRtp_codecs_filtered'] = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['rtcRtp_codecs_filtered'] = { got: 'API absent', expected: 'n/a', pass: true };
  }

  // ── document.fonts enumeration blocked ───────────────────────────────────
  if (document.fonts) {
    let _fCount = 0;
    try { document.fonts.forEach(() => _fCount++); } catch(e) {}
    checkTrue('fonts_enum_blocked', _fCount === 0);
    checkTrue('fonts_size_zero',    document.fonts.size === 0);
  } else {
    results['fonts_enum_blocked'] = { got: 'API absent', expected: 'n/a', pass: true };
    results['fonts_size_zero']    = { got: 'API absent', expected: 'n/a', pass: true };
  }

  return results;
})()`;

// ── Run in Playwright WebKit ────────────────────────────────────────────────
let webkit;
try {
  ({ webkit } = await import('playwright'));
} catch {
  console.error('ERROR: playwright not installed — run: npm install playwright');
  process.exit(1);
}

const browser = await webkit.launch({ headless: true });
const context = await browser.newContext();

if (shieldJS) {
  await context.addInitScript({ content: shieldJS });
}

const page = await context.newPage();
await page.setContent('<html><body><canvas id="c"></canvas></body></html>');

const results = await page.evaluate(PROBE);
await browser.close();

// ── Report ──────────────────────────────────────────────────────────────────
const vectors = Object.entries(results);
const passed = vectors.filter(([, r]) => r.pass);
const failed = vectors.filter(([, r]) => !r.pass);

const RESET = '\x1b[0m', GREEN = '\x1b[32m', RED = '\x1b[31m', BOLD = '\x1b[1m', DIM = '\x1b[2m';

console.log(`\n${BOLD}BearBrowser Fingerprint Shield — ${noShield ? 'BASELINE (no shield)' : 'SHIELDED'}${RESET}`);
console.log(`${'─'.repeat(60)}`);

for (const [name, { got, expected, pass }] of vectors) {
  const icon = pass ? `${GREEN}✓${RESET}` : `${RED}✗${RESET}`;
  const detail = pass ? '' : `  ${DIM}got: ${got}  expected: ${expected}${RESET}`;
  console.log(`  ${icon}  ${name}${detail}`);
}

console.log(`${'─'.repeat(60)}`);
console.log(`${BOLD}${passed.length}/${vectors.length} passed${RESET}  ${failed.length > 0 ? `${RED}${failed.length} FAILED${RESET}` : `${GREEN}all clear${RESET}`}`);

if (failed.length > 0) {
  console.log(`\n${RED}${BOLD}FAILED vectors:${RESET}`);
  for (const [name, { got, expected }] of failed) {
    console.log(`  ${RED}✗${RESET} ${name}: got=${got}  expected=${expected}`);
  }
  process.exit(1);
}

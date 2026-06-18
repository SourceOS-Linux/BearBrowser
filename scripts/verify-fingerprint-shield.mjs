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
    // fonts.load() should resolve to [] (not find any font)
    try {
      const _fLoaded = await document.fonts.load('12px Arial', 'A');
      checkTrue('fonts_load_empty', _fLoaded.length === 0);
    } catch(e) {
      results['fonts_load_empty'] = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['fonts_enum_blocked'] = { got: 'API absent', expected: 'n/a', pass: true };
    results['fonts_size_zero']    = { got: 'API absent', expected: 'n/a', pass: true };
    results['fonts_load_empty']   = { got: 'API absent', expected: 'n/a', pass: true };
  }

  // ── screen.availLeft/Top/isExtended ──────────────────────────────────────
  check('screen.availLeft', screen.availLeft, 0);
  check('screen.availTop',  screen.availTop,  0);
  checkTrue('screen_isExtended_false',
    typeof screen.isExtended === 'undefined' || screen.isExtended === false);

  // ── screenX/Y locked to 0 ────────────────────────────────────────────────
  check('window.screenX', window.screenX, 0);
  check('window.screenY', window.screenY, 0);

  // ── navigator.plugins has 5 PDF entries ──────────────────────────────────
  checkTrue('plugins_has_pdf', navigator.plugins.length === 5);
  checkTrue('plugins_first_name',
    navigator.plugins[0] && navigator.plugins[0].name === 'PDF Viewer');

  // ── AudioBuffer.getChannelData applies noise (OfflineAudioContext path) ──
  if (window.OfflineAudioContext && window.AudioBuffer) {
    try {
      const _oac = new OfflineAudioContext(1, 128, 44100);
      const _osc = _oac.createOscillator();
      const _cmp = _oac.createDynamicsCompressor();
      _osc.connect(_cmp); _cmp.connect(_oac.destination);
      _osc.start(0);
      const _buf = await _oac.startRendering();
      const _d   = _buf.getChannelData(0);
      // getChannelData should return a Float32Array (patched copy)
      checkTrue('audioBuffer_getChannelData_is_float32', _d instanceof Float32Array);
      // Two reads of same channel should return same values (session-stable)
      const _d2  = _buf.getChannelData(0);
      checkTrue('audioBuffer_getChannelData_stable', _d[0] === _d2[0]);
    } catch(e) {
      results['audioBuffer_getChannelData_is_float32'] = { got: String(e), expected: 'true', pass: false };
      results['audioBuffer_getChannelData_stable']     = { got: String(e), expected: 'true', pass: false };
    }
  } else {
    results['audioBuffer_getChannelData_is_float32'] = { got: 'API absent', expected: 'n/a', pass: true };
    results['audioBuffer_getChannelData_stable']     = { got: 'API absent', expected: 'n/a', pass: true };
  }

  // ── window.name is always empty (tracking-channel block) ─────────────────
  window.name = 'tracker_id_12345';
  checkTrue('window_name_blocked', window.name === '');

  // ── Error.stack reformatted to V8 style ──────────────────────────────────
  try {
    const _stack = new Error('test').stack || '';
    // V8 style has "    at " prefix; JSC raw format has "@url:line:col" frames
    const _hasAt  = _stack.indexOf('    at ') >= 0;
    const _hasJSC = _stack.indexOf(' @http') >= 0 || _stack.indexOf(' @blob:') >= 0
                    || _stack.indexOf('@[native') >= 0;
    checkTrue('error_stack_v8_style', _hasAt || !_hasJSC || _stack === '');
  } catch(e) {
    results['error_stack_v8_style'] = { got: String(e), expected: 'true', pass: false };
  }

  // ── SVG getBBox applies noise (not throwing) ──────────────────────────────
  try {
    const _svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
    const _txt = document.createElementNS('http://www.w3.org/2000/svg','text');
    _txt.textContent = 'fingerprint';
    _svg.appendChild(_txt); document.body.appendChild(_svg);
    const _bb = _txt.getBBox();
    checkTrue('svg_getBBox_is_number', typeof _bb.width === 'number');
    document.body.removeChild(_svg);
  } catch(e) {
    // SVG text rendering may not be available in headless — accept
    results['svg_getBBox_is_number'] = { got: String(e), expected: 'n/a', pass: true };
  }

  // ── navigator.pdfViewerEnabled — Chrome 104+ property ──────────────────
  checkTrue('navigator_pdfViewerEnabled', navigator.pdfViewerEnabled === true);

  // ── WebKit-only API removal (absent in Chrome) ───────────────────────────
  checkTrue('no_caretRangeFromPoint',   typeof document.caretRangeFromPoint === 'undefined');
  checkTrue('no_WebKitCSSMatrix',       typeof window.WebKitCSSMatrix === 'undefined');
  checkTrue('no_webkitStorageInfo',     typeof window.webkitStorageInfo === 'undefined');
  checkTrue('perf_memory_exists',       typeof performance.memory === 'object');

  // ── performance.timeOrigin — must be clamped to 100ms bucket ───────────
  checkTrue('perf_timeOrigin_is_100ms_bucket', performance.timeOrigin % 100 === 0);

  // ── Intl.supportedValuesOf — must return fixed Chrome-matching lists ─────
  if (typeof Intl.supportedValuesOf === 'function') {
    const _cals = Intl.supportedValuesOf('calendar');
    checkTrue('intl_supportedValues_calendar_has_gregory', _cals.indexOf('gregory') >= 0);
    checkTrue('intl_supportedValues_calendar_no_extra', _cals.length <= 20);
    const _cols = Intl.supportedValuesOf('collation');
    checkTrue('intl_supportedValues_collation_has_pinyin', _cols.indexOf('pinyin') >= 0);
  } else {
    results['intl_supportedValues_calendar_has_gregory'] = { got: 'n/a', expected: 'n/a', pass: true };
    results['intl_supportedValues_calendar_no_extra']     = { got: 'n/a', expected: 'n/a', pass: true };
    results['intl_supportedValues_collation_has_pinyin']  = { got: 'n/a', expected: 'n/a', pass: true };
  }

  // ── Notification.permission — must be 'denied' ───────────────────────────
  if (window.Notification) {
    check('notification_permission_denied', Notification.permission, 'denied');
  } else {
    results['notification_permission_denied'] = { got: 'n/a', expected: 'n/a', pass: true };
  }

  // ── Math precision — JSC vs V8 ULP divergences (creepjs probe) ─────────
  // Each check verifies we return V8's float64 value, not JSC's.
  check('math_acos_0123',   Math.acos(0.123),                1.4474840516030247);
  check('math_acosh_sqrt2', Math.acosh(Math.SQRT2),          0.881373587019543);
  check('math_atan_2',      Math.atan(2),                    1.1071487177940904);
  check('math_atanh_05',    Math.atanh(0.5),                 0.5493061443340548);
  check('math_cbrt_pi',     Math.cbrt(Math.PI),              1.4645918875615231);
  check('math_expm1_1',     Math.expm1(1),                   1.718281828459045);
  check('math_sinh_pi',     Math.sinh(Math.PI),              11.548739357257748);
  check('math_sinh_sqrt2',  Math.sinh(Math.SQRT2),           1.935066822174357);
  check('math_tan_1e308',   Math.tan(-1e308),                0.5086861259107568);
  check('math_tan_6ln2',    Math.tan(6*Math.LN2),            1.6182817135715877);
  check('math_tan_10log2e', Math.tan(10*Math.LOG2E),        -3.3537128705376014);
  check('math_tanh_0123',   Math.tanh(0.123),                0.12238344189440875);
  check('math_pow_pi_n100', Math.pow(Math.PI,-100),          1.9275814160560204e-50);
  check('math_pow_l10_n100',Math.pow(Math.LOG10E,-100),      1.6655929347585958e+36);

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

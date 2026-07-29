/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearTrapChild — the honeypot suite, content-process side. Zero-trust: we
 * assume every page may try to fingerprint or exfiltrate, so we bait and detect.
 *
 * Two honeypots, both DETECTION-first (they never break the page):
 *
 * 1. FINGERPRINT HONEYPOT — instrument the browser-fingerprinting surfaces
 *    (canvas readback, WebGL renderer, AudioContext, font/plugin/hardware
 *    enumeration). A page that touches ≥ THRESHOLD distinct surfaces in one
 *    document is almost certainly building a fingerprint; we count the probes
 *    per surface and report the offending origin. RFP already spoofs the VALUES;
 *    BearTrap adds the missing half — telling you WHO tried, and how hard.
 *
 * 2. CANARY TOKEN — a unique, page-scoped decoy string is planted where a
 *    scraper/exfiltrator would grab it (a hidden honeypot field + a getter on a
 *    decoy global). If that exact token later appears in an outbound request
 *    body/URL (matched by BearTrapParent against the network side), that's a
 *    provable exfiltration attempt, attributed to the script that read it.
 *
 * Reports go to BearTrapParent, which surfaces them (BearNet badge + a sealed
 * receipt) and can feed the firewall. Best-effort + wrapped: a honeypot must
 * never be what breaks a page.
 *
 * Pref: bearbrowser.honeypot.enabled (default true)
 */

const FP_THRESHOLD = 3; // distinct surfaces before we call it fingerprinting

export class BearTrapChild extends JSWindowActorChild {
  #probes = null; // Map<surface, count>
  #canary = null;
  #reported = false;

  handleEvent(event) {
    if (event.type === "DOMWindowCreated") {
      this.#arm();
    }
  }

  #arm() {
    let win;
    try {
      win = this.contentWindow;
      if (!win || !win.location || !/^https?:$/.test(win.location.protocol)) {
        return; // only real web content
      }
    } catch (e) {
      return;
    }
    this.#probes = new Map();
    this.#canary = "bt-" + Math.random().toString(36).slice(2) + Date.now().toString(36);

    try {
      this.#instrumentFingerprinting(win);
      this.#plantCanary(win);
    } catch (e) {
      /* never break the page */
    }
  }

  #note(surface) {
    if (!this.#probes) return;
    this.#probes.set(surface, (this.#probes.get(surface) || 0) + 1);
    if (this.#probes.size >= FP_THRESHOLD && !this.#reported) {
      this.#reported = true;
      this.#report("fingerprint");
    }
  }

  // Wrap the classic fingerprinting surfaces to COUNT probing. Values are left
  // to RFP; we only observe. Wrappers are transparent and fall through.
  #instrumentFingerprinting(win) {
    const note = (s) => this.#note(s);
    const wrap = (obj, name, surface) => {
      if (!obj || typeof obj[name] !== "function") return;
      const orig = obj[name];
      try {
        obj[name] = function (...args) {
          note(surface);
          return orig.apply(this, args);
        };
      } catch (e) {}
    };

    const C = win.HTMLCanvasElement && win.HTMLCanvasElement.prototype;
    wrap(C, "toDataURL", "canvas");
    wrap(C, "toBlob", "canvas");
    const C2D = win.CanvasRenderingContext2D && win.CanvasRenderingContext2D.prototype;
    wrap(C2D, "getImageData", "canvas");
    wrap(C2D, "measureText", "canvas-text");

    for (const gl of ["WebGLRenderingContext", "WebGL2RenderingContext"]) {
      const P = win[gl] && win[gl].prototype;
      wrap(P, "getParameter", "webgl");
      wrap(P, "getExtension", "webgl");
      wrap(P, "getShaderPrecisionFormat", "webgl");
    }

    const AC = win.AudioContext || win.webkitAudioContext;
    if (AC && AC.prototype) {
      wrap(AC.prototype, "createAnalyser", "audio");
      wrap(AC.prototype, "createOscillator", "audio");
    }

    // Enumeration getters — navigator.plugins / hardwareConcurrency / fonts.
    //
    // Some of these are CLAMPED here, not merely counted. Measured against the
    // shipped v150.0.1 with scripts/audit/: navigator.hardwareConcurrency
    // returned the machine's REAL core count (8) even though RFP was
    // demonstrably active on that same page (timezone spoofed to
    // Atlantic/Reykjavik, timers quantized) — and neither
    // `dom.maxHardwareConcurrency=2` nor `privacy.fingerprintingProtection`
    // changed it. Rather than patch dom/base/Navigator.cpp blind (no local
    // source tree; a bad hunk breaks every nightly), normalize it inside the
    // interception we already own and already ship.
    //
    // 🔴 This rides the honeypot actor, so it follows
    // `bearbrowser.honeypot.enabled`. Re-measure with scripts/audit/ after any
    // change — never assume the clamp landed.
    const CLAMP = {
      // Tor Browser reports 2; anything above that is per-machine entropy.
      hardwareConcurrency: v => (typeof v === "number" && v > 2 ? 2 : v),
      deviceMemory: v => (typeof v === "number" && v > 2 ? 2 : v),
    };
    const wrapGetter = (obj, prop, surface) => {
      try {
        const d = Object.getOwnPropertyDescriptor(obj, prop);
        if (!d || !d.get) return;
        const g = d.get;
        const clamp = CLAMP[prop];
        Object.defineProperty(obj, prop, {
          configurable: true,
          get() {
            note(surface);
            const v = g.call(this);
            return clamp ? clamp(v) : v;
          },
        });
      } catch (e) {}
    };
    const N = win.Navigator && win.Navigator.prototype;
    wrapGetter(N, "plugins", "plugins");
    wrapGetter(N, "mimeTypes", "plugins");
    wrapGetter(N, "hardwareConcurrency", "hardware");
    wrapGetter(N, "deviceMemory", "hardware");
    if (win.document && win.document.fonts) {
      wrap(win.document.fonts, "check", "fonts");
    }
  }

  // Plant a page-scoped canary the exfiltrator would take. Detection of the
  // token in outbound traffic happens in BearTrapParent (network side).
  #plantCanary(win) {
    try {
      const doc = win.document;
      const inject = () => {
        if (!doc.body || doc.getElementById("__beartrap")) return;
        const f = doc.createElement("input");
        f.id = "__beartrap";
        f.name = "email"; // bait a form scraper
        f.value = this.#canary + "@example.invalid";
        f.setAttribute("autocomplete", "email");
        f.style.cssText =
          "position:absolute!important;left:-9999px!important;top:-9999px!important;width:1px;height:1px;opacity:0";
        f.setAttribute("aria-hidden", "true");
        f.tabIndex = -1;
        doc.body.appendChild(f);
      };
      if (doc.body) inject();
      else doc.addEventListener("DOMContentLoaded", inject, { once: true });
      // Register the canary with the parent so the network side can match it.
      this.sendAsyncMessage("BearTrap:Canary", {
        token: this.#canary,
        origin: win.location.origin,
      });
    } catch (e) {}
  }

  #report(kind) {
    try {
      const win = this.contentWindow;
      const surfaces = Object.fromEntries(this.#probes || []);
      this.sendAsyncMessage("BearTrap:Detected", {
        kind,
        origin: win.location.origin,
        url: win.location.href,
        surfaces,
        surfaceCount: this.#probes ? this.#probes.size : 0,
      });
    } catch (e) {}
  }
}

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearTrapMonitor — the network side of the honeypot suite (parent-process
 * singleton). Holds the per-origin canary registry (fed by BearTrapChild via
 * BearTrapParent) and watches every outbound HTTP request. If a page's own
 * decoy canary token ever appears in an outbound URL/query OR in a POST/PUT
 * request body — i.e. a script scraped the honeypot field and is exfiltrating
 * it — that is, by construction, never legitimate: BearTrap ATTRIBUTES it
 * (which origin, to which destination, and via url|body) and CANCELS the
 * request. Zero-trust: we don't just detect the leak, we stop it.
 *
 * Wired up once from the autoconfig (imports this module + calls start()).
 */

const Cr = Components.results;
const Cc = Components.classes;

// Cap on how much of an outbound POST/PUT body we scan for a canary. Tokens
// live in small form/JSON beacons; large uploads (files) are not where a
// scraped decoy field ends up, and reading megabytes on every request would
// cost more than it's worth.
const MAX_BODY_SCAN = 262144; // 256 KB

// ── BearWall denylist ───────────────────────────────────────────────────────
// Vendor endpoints that must never be contacted, enforced at the channel layer
// so no pref, no upstream merge and no hardcoded URL can reach them.
//
// 🔴 NOT on this list, on purpose (see docs/sovereign-remote-settings-mirror.md):
//   firefox.settings.services.mozilla.com — carries CRLite certificate
//     REVOCATION, CT logs and malware blocklists. Blocking it would trade
//     security for privacy. It gets a sovereign mirror instead.
//   addons.mozilla.org / services.addons.mozilla.org — add-on SECURITY updates.
const DENY_HOSTS = new Set([
  "detectportal.firefox.com",        // captive-portal probe; Mozilla EXEMPTS it
  "incoming.telemetry.mozilla.org",  // from HTTPS-Only, so it goes cleartext
  "telemetry.mozilla.org",
  "dap.services.mozilla.com",        // DAP "privacy-preserving" telemetry
  "aus5.mozilla.org",                // GMP/DRM + system add-on updates: leaks
  "aus4.mozilla.org",                //   %OS_VERSION%/%BUILD_TARGET%/%BUILD_ID%
  "ads.mozilla.org",
  "contile.services.mozilla.com",    // sponsored tiles
  "spocs.getpocket.com",             // Pocket sponsored content
  "getpocket.com",
  "normandy.cdn.mozilla.net",        // remote experiment recipes
  "location.services.mozilla.com",   // region lookup
  "push.services.mozilla.com",
  "shavar.services.mozilla.com",
  "safebrowsing.googleapis.com",     // Google SafeBrowsing
  "www.googleapis.com",              // geolocation endpoint lives here
  "profiler.firefox.com",
  "monitor.firefox.com",
  "relay.firefox.com",
  "vpn.mozilla.org",
  "fpn.firefox.com",
  "model-hub.mozilla.org",           // ML model downloads
  "mozilla-ohttp.fastly-edge.com",   // ad-delivery OHTTP relay
]);
const DENY_SUFFIXES = [
  ".telemetry.mozilla.org",
  ".ohttp-gateway.prod.webservices.mozgcp.net",
];

export const BearTrapMonitor = {
  _canaries: new Map(), // origin -> Set<token>
  _started: false,
  _blocked: new Map(), // host -> count (surfaced via /honeypot for BearNet)

  // True if this host must never be contacted.
  isDenied(host) {
    const h = String(host).toLowerCase();
    if (DENY_HOSTS.has(h)) {
      return true;
    }
    return DENY_SUFFIXES.some(s => h.endsWith(s));
  },

  // Count + report, but only report a given host ONCE per session — these fire
  // on a timer and would otherwise spam the panel.
  noteBlockedHost(host) {
    const n = (this._blocked.get(host) || 0) + 1;
    this._blocked.set(host, n);
    if (n !== 1) {
      return;
    }
    const record = { kind: "vendor-blocked", dest: host, blocked: true };
    try {
      fetch("http://127.0.0.1:8093/honeypot", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(record),
      }).catch(() => {});
    } catch (e) {}
    try {
      Services.obs.notifyObservers(
        { wrappedJSObject: record },
        "beartrap-detection"
      );
    } catch (e) {}
  },

  registerCanary(origin, token) {
    if (!origin || !token) return;
    if (!this._canaries.has(origin)) {
      this._canaries.set(origin, new Set());
    }
    this._canaries.get(origin).add(token);
  },

  match(text) {
    if (!text) {
      return null;
    }
    for (const [origin, tokens] of this._canaries) {
      for (const t of tokens) {
        if (text.includes(t)) {
          return { origin, token: t };
        }
      }
    }
    return null;
  },

  start() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      Services.obs.addObserver(this, "http-on-modify-request");
    } catch (e) {}
  },

  observe(subject, topic) {
    if (topic !== "http-on-modify-request") {
      return;
    }

    // ── BearWall: hard outbound denylist, enforced in OUR code ──────────────
    // Runs BEFORE the canary check and regardless of prefs. Prefs and
    // source-strips both assume the vendor plays fair; this does not. Firefox
    // hardcodes some of these (TranslationsParent embeds the RemoteSettings URL
    // six times) and EXEMPTS its captive-portal check from HTTPS-Only, so it
    // goes out in CLEARTEXT by design. A pref can be flipped, an upstream merge
    // can reintroduce a URL — this cancels the channel either way.
    try {
      const ch0 = subject.QueryInterface(Ci.nsIHttpChannel);
      const host = ch0.URI && ch0.URI.host;
      if (host && this.isDenied(host)) {
        // Vendor traffic honeypot — pref-gated. Off = block (default, safe).
        // On = redirect at the CHANNEL LAYER to a local sink (the capture
        // sidecar's /vendor-sink) that records the FULL request the vendor was
        // trying to send. That is what "honeypot Mozilla" actually means:
        // instead of just refusing, watch what they intended to leak.
        // Only harmless targets get the honeypot treatment; hosts on
        // `SINK_UNSAFE` are always blocked (they can execute code / update
        // add-ons if answered plausibly).
        let honeypot = false;
        try {
          honeypot = Services.prefs.getBoolPref(
            "bearbrowser.honeypot.vendor.sink", false);
        } catch (e) {}
        const SINK_UNSAFE = /aus\d+\.mozilla\.org|addons\.mozilla\.org|systemAddon/i;
        if (honeypot && !SINK_UNSAFE.test(host)) {
          try {
            // Redirect to loopback sink; sidecar returns benign 204 + logs the
            // full request headers/body it would have received. The client
            // never talks to the real vendor.
            const sinkURI = Services.io.newURI(
              "http://127.0.0.1:8093/vendor-sink" +
                "?dest=" + encodeURIComponent(host) +
                "&path=" + encodeURIComponent(ch0.URI.pathQueryRef || "/"));
            ch0.redirectTo(sinkURI);
            this.noteBlockedHost(host + " → sink");
            return;
          } catch (e) { /* fall through to hard block */ }
        }
        ch0.cancel(Cr.NS_ERROR_ABORT);
        this.noteBlockedHost(host);
        return;
      }
    } catch (e) {}

    // No decoys registered yet -> nothing can leak; skip the canary work.
    if (!this._canaries.size) {
      return;
    }
    try {
      const ch = subject.QueryInterface(Ci.nsIHttpChannel);
      const url = ch.URI && ch.URI.spec;

      // 1. The canary in an outbound URL/query = a beacon exfiltrating the decoy.
      let hit = this.match(url);
      let via = "url";

      // 2. …or in a POST/PUT body — form fields and JSON beacons are the more
      //    common exfil path. Read the upload stream and REWIND it so the real
      //    request still sends its full, untouched body.
      if (!hit) {
        const body = this._readUploadBody(ch);
        if (body) {
          const bhit = this.match(body);
          if (bhit) {
            hit = bhit;
            via = "body";
          }
        }
      }

      if (hit) {
        let dest = "";
        try {
          dest = ch.URI.host;
        } catch (e) {}
        this.report(hit, dest, via);
        // A canary leak is never legitimate traffic — stop it.
        try {
          ch.cancel(Cr.NS_ERROR_ABORT);
        } catch (e) {}
      }
    } catch (e) {}
  },

  // Read the outbound request body for canary scanning WITHOUT consuming it.
  // Only seekable bodies are touched (so we can rewind); non-seekable streams
  // (e.g. some file uploads) are skipped rather than risk mangling the request.
  // Returns the leading bytes as a string, or null.
  _readUploadBody(ch) {
    let stream;
    try {
      stream = ch.QueryInterface(Ci.nsIUploadChannel).uploadStream;
    } catch (e) {
      return null; // not an upload channel / no body
    }
    if (!stream) {
      return null;
    }
    let seekable;
    try {
      seekable = stream.QueryInterface(Ci.nsISeekableStream);
    } catch (e) {
      return null; // can't rewind -> leave it strictly alone
    }
    let text = null;
    try {
      const n = Math.min(stream.available(), MAX_BODY_SCAN);
      if (n > 0) {
        const bin = Cc[
          "@mozilla.org/binaryinputstream;1"
        ].createInstance(Ci.nsIBinaryInputStream);
        bin.setInputStream(stream);
        // Tokens are ASCII, so a byte-string read is sufficient for matching.
        text = bin.readBytes(n);
      }
    } catch (e) {
      text = null;
    } finally {
      // ALWAYS rewind, even on error, so the body goes out intact.
      try {
        seekable.seek(Ci.nsISeekableStream.NS_SEEK_SET, 0);
      } catch (e) {}
    }
    return text;
  },

  report(hit, dest, via) {
    const record = {
      kind: "exfil",
      origin: hit.origin,
      dest,
      via,
      blocked: true,
    };
    // Best-effort to the loopback sidecar so BearNet surfaces it.
    try {
      fetch("http://127.0.0.1:8093/honeypot", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(record),
      }).catch(() => {});
    } catch (e) {}
    // Chrome-side badge / notification.
    try {
      Services.obs.notifyObservers(
        { wrappedJSObject: record },
        "beartrap-detection"
      );
    } catch (e) {}
  },
};

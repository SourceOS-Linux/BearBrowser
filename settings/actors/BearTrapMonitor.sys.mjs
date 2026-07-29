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

export const BearTrapMonitor = {
  _canaries: new Map(), // origin -> Set<token>
  _started: false,

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
    // No decoys registered yet -> nothing can leak; skip all work.
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

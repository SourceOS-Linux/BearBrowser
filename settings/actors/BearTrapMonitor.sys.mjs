/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearTrapMonitor — the network side of the honeypot suite (parent-process
 * singleton). Holds the per-origin canary registry (fed by BearTrapChild via
 * BearTrapParent) and watches every outbound HTTP request. If a page's own
 * decoy canary token ever appears in an outbound URL — i.e. a script scraped the
 * honeypot field and is exfiltrating it — that is, by construction, never
 * legitimate: BearTrap ATTRIBUTES it (which origin, to which destination) and
 * CANCELS the request. Zero-trust: we don't just detect the leak, we stop it.
 *
 * Wired up once from the autoconfig (imports this module + calls start()).
 */

const Cr = Components.results;

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
    try {
      const ch = subject.QueryInterface(Ci.nsIHttpChannel);
      const url = ch.URI && ch.URI.spec;
      // The canary in an outbound URL/query = a beacon exfiltrating the decoy.
      const hit = this.match(url);
      if (hit) {
        let dest = "";
        try {
          dest = ch.URI.host;
        } catch (e) {}
        this.report(hit, dest, "url");
        // A canary leak is never legitimate traffic — stop it.
        try {
          ch.cancel(Cr.NS_ERROR_ABORT);
        } catch (e) {}
      }
    } catch (e) {}
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

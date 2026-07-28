/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearTrapParent — honeypot suite, parent-process side.
 *
 * Receives detections from BearTrapChild and (a) notifies the chrome via an
 * observer topic so BearNet / a toolbar badge can surface "N fingerprinting
 * attempts on this page", and (b) best-effort reports to the loopback capture
 * sidecar (/honeypot) so the network map can flag the offending origin. It also
 * registers per-origin canary tokens; when the network side sees a token in an
 * outbound request, that's an attributable exfiltration.
 *
 * Never throws into the content path — a honeypot must not break browsing.
 */

// origin -> Set(canary tokens). Consulted by the network-side matcher.
const CANARIES = new Map();

export class BearTrapParent extends JSWindowActorParent {
  async receiveMessage(msg) {
    try {
      if (msg.name === "BearTrap:Canary") {
        const { token, origin } = msg.data || {};
        if (token && origin) {
          if (!CANARIES.has(origin)) CANARIES.set(origin, new Set());
          CANARIES.get(origin).add(token);
        }
        return;
      }
      if (msg.name === "BearTrap:Detected") {
        this.#onDetection(msg.data || {});
      }
    } catch (e) {
      /* swallow — honeypots never break the page */
    }
  }

  #onDetection(data) {
    // 1. Notify chrome (BearNet badge / toolbar) — observers are cheap + safe.
    try {
      Services.obs.notifyObservers(
        { wrappedJSObject: data },
        "beartrap-detection"
      );
    } catch (e) {}

    // 2. Best-effort report to the loopback capture sidecar for the network map.
    //    Fire-and-forget; the sidecar may not be running.
    try {
      const body = JSON.stringify({
        kind: data.kind,
        origin: data.origin,
        surfaces: data.surfaces,
        surfaceCount: data.surfaceCount,
      });
      fetch("http://127.0.0.1:8093/honeypot", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      }).catch(() => {});
    } catch (e) {}
  }

  /** For the network-side matcher: is `text` a registered canary? */
  static canaryHit(text) {
    if (!text) return null;
    for (const [origin, tokens] of CANARIES) {
      for (const t of tokens) {
        if (text.includes(t)) return { origin, token: t };
      }
    }
    return null;
  }
}

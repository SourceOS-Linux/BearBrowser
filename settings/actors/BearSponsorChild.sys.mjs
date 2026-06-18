/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearSponsorChild — YouTube SponsorBlock integration running in content process.
 *
 * Watches for YouTube SPA navigations, extracts videoId, asks BearSponsorParent
 * to fetch segment data, then polls video.currentTime to skip matched segments.
 * Shows a brief dismissible toast when a segment is skipped.
 *
 * Pref: bearbrowser.sponsorblock.enabled (default true)
 */

export class BearSponsorChild extends JSWindowActorChild {
  #videoId = null;
  #segments = [];
  #pollTimer = null;
  #titleObserver = null;
  #enabled = false;

  actorCreated() {
    this.#enabled = Services.prefs.getBoolPref(
      "bearbrowser.sponsorblock.enabled",
      true
    );
  }

  handleEvent(event) {
    if (!this.#enabled) return;
    const doc = this.document;
    if (!doc?.location?.hostname?.includes("youtube.com")) return;

    if (event.type === "DOMContentLoaded" || event.type === "pageshow") {
      this.#startWatching();
    }
  }

  #startWatching() {
    // Watch <title> mutations — YouTube updates it on SPA navigation
    const doc = this.document;
    const titleEl = doc.querySelector("title");
    if (!titleEl) return;

    this.#titleObserver?.disconnect();
    this.#titleObserver = new doc.defaultView.MutationObserver(() => {
      this.#checkVideoId();
    });
    this.#titleObserver.observe(titleEl, { childList: true, characterData: true });
    this.#checkVideoId();
  }

  #checkVideoId() {
    const url = this.document?.location?.href ?? "";
    const match = url.match(/[?&]v=([a-zA-Z0-9_-]{11})/);
    const vid = match?.[1] ?? null;
    if (!vid || vid === this.#videoId) return;

    this.#videoId = vid;
    this.#segments = [];
    this.#stopPoll();
    this.sendAsyncMessage("BearSponsor:VideoChanged", { videoId: vid });
  }

  receiveMessage(msg) {
    if (msg.name !== "BearSponsor:Segments") return;
    this.#segments = msg.data.segments ?? [];
    if (this.#segments.length) this.#startPoll();
  }

  #startPoll() {
    this.#stopPoll();
    const win = this.document?.defaultView;
    if (!win) return;
    this.#pollTimer = win.setInterval(() => this.#tick(), 500);
  }

  #stopPoll() {
    if (this.#pollTimer !== null) {
      this.document?.defaultView?.clearInterval(this.#pollTimer);
      this.#pollTimer = null;
    }
  }

  #tick() {
    const video = this.document?.querySelector("video");
    if (!video || video.paused) return;
    const t = video.currentTime;

    for (const seg of this.#segments) {
      if (t >= seg.startTime && t < seg.endTime - 0.3) {
        video.currentTime = seg.endTime;
        this.#showToast(seg.category);
        break;
      }
    }
  }

  #showToast(category) {
    const doc = this.document;
    doc.querySelector("#bb-skip-toast")?.remove();

    const toast = doc.createElement("div");
    toast.id = "bb-skip-toast";
    Object.assign(toast.style, {
      position: "fixed",
      bottom: "80px",
      right: "20px",
      zIndex: "2147483647",
      background: "rgba(15,15,15,.9)",
      color: "#fff",
      padding: "8px 14px",
      borderRadius: "4px",
      font: "13px/1.5 -apple-system,sans-serif",
      pointerEvents: "none",
      backdropFilter: "blur(4px)",
    });
    toast.textContent = `Skipped: ${category.replace(/_/g, " ")}`;
    doc.body?.appendChild(toast);
    doc.defaultView?.setTimeout(() => toast.remove(), 2500);
  }

  didDestroy() {
    this.#titleObserver?.disconnect();
    this.#stopPoll();
  }
}

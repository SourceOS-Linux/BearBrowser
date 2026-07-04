/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearSponsorParent — fetches SponsorBlock segment data for YouTube videos.
 *
 * Privacy model: only the first 4 hex chars of SHA-256(videoId) are sent to
 * the SponsorBlock API. The server returns all matching video entries; the
 * parent filters for the exact videoId locally before forwarding segments
 * to the content process. No full videoId leaves the browser.
 *
 * Categories blocked by default: sponsor, selfpromo, interaction, intro,
 * outro, preview, filler. Music (poi_highlight, exclusive_access) are left
 * to avoid breaking music videos.
 */

const SKIP_CATEGORIES = [
  "sponsor",
  "selfpromo",
  "interaction",
  "intro",
  "outro",
  "preview",
  "filler",
];

const API_BASE = "https://sponsor.ajay.app/api/skipSegments";
const HASH_PREFIX_LEN = 4;

export class BearSponsorParent extends JSWindowActorParent {
  async receiveMessage(msg) {
    if (msg.name !== "BearSponsor:VideoChanged") return;

    const { videoId } = msg.data;
    if (!videoId || !/^[a-zA-Z0-9_-]{11}$/.test(videoId)) return;

    try {
      const segments = await this.#fetchSegments(videoId);
      this.sendAsyncMessage("BearSponsor:Segments", { segments });
    } catch {
      // Network failures are silent — no segments means no skipping
    }
  }

  async #fetchSegments(videoId) {
    const hashPrefix = await this.#sha256prefix(videoId);
    const url = `${API_BASE}/${hashPrefix}?categories=${encodeURIComponent(JSON.stringify(SKIP_CATEGORIES))}`;

    const resp = await fetch(url, {
      method: "GET",
      credentials: "omit",
      cache: "default",
    });

    if (!resp.ok) return [];

    const data = await resp.json();

    // Filter to exact match and flatten segments
    for (const entry of data) {
      if (entry.videoID === videoId && Array.isArray(entry.segments)) {
        return entry.segments
          .filter(s => SKIP_CATEGORIES.includes(s.category))
          .map(s => ({
            startTime: s.segment[0],
            endTime: s.segment[1],
            category: s.category,
            UUID: s.UUID,
          }));
      }
    }
    return [];
  }

  async #sha256prefix(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hashBuffer = await crypto.subtle.digest("SHA-256", data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray
      .map(b => b.toString(16).padStart(2, "0"))
      .join("")
      .slice(0, HASH_PREFIX_LEN);
  }
}

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearClipParent — persists research clips to local JSONL and optionally
 * forwards to Zotero's local connector API.
 *
 * Receives BearClip:Save from the content process, appends a clip record to
 * {profileDir}/research/clips.jsonl, and attempts a Zotero API call on
 * http://127.0.0.1:23119/connector/saveItems if Zotero is running.
 *
 * The local JSONL is the primary store; Zotero is opportunistic.
 */

const CLIPS_FILENAME = "clips.jsonl";
const ZOTERO_PING = "http://127.0.0.1:23119/connector/ping";
const ZOTERO_SAVE = "http://127.0.0.1:23119/connector/saveItems";

export class BearClipParent extends JSWindowActorParent {
  async receiveMessage(msg) {
    if (msg.name !== "BearClip:Save") return;
    const { clip } = msg.data;
    if (!clip || typeof clip !== "object") return;

    const record = {
      ...clip,
      savedAt: new Date().toISOString(),
      schema: "bearbrowser-clip/v1",
    };

    await this.#writeLocal(record);
    await this.#tryZotero(record);
  }

  async #writeLocal(record) {
    const clipsDir = PathUtils.join(PathUtils.profileDir, "research");
    await IOUtils.makeDirectory(clipsDir, { ignoreExisting: true });
    const path = PathUtils.join(clipsDir, CLIPS_FILENAME);
    const line = JSON.stringify(record) + "\n";
    await IOUtils.writeUTF8(path, line, { mode: "append" });
  }

  async #tryZotero(record) {
    // Quick ping first so we don't hang on a connection if Zotero isn't open
    try {
      const ping = await fetch(ZOTERO_PING, {
        method: "GET",
        signal: AbortSignal.timeout(500),
        credentials: "omit",
      });
      if (!ping.ok) return;
    } catch {
      return; // Zotero not running — that's fine
    }

    const zoteroItem = {
      items: [{
        itemType: record.itemType ?? "webpage",
        title: record.title ?? "",
        url: record.url ?? "",
        abstractNote: record.abstract ?? "",
        date: record.date ?? record.savedAt,
        extra: record.doi ? `DOI: ${record.doi}` : "",
        tags: record.tags ?? [],
        creators: (record.authors ?? []).map(a => ({
          creatorType: "author",
          firstName: a.split(" ").slice(0, -1).join(" "),
          lastName: a.split(" ").slice(-1)[0] ?? a,
        })),
      }],
    };

    try {
      await fetch(ZOTERO_SAVE, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Zotero-Allowed-Request": "1" },
        body: JSON.stringify(zoteroItem),
        signal: AbortSignal.timeout(3000),
        credentials: "omit",
      });
    } catch {
      // Zotero save failed — local JSONL is already written
    }
  }
}

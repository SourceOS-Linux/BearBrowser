/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearCaptureParent — downloads media URLs via the platform download manager.
 *
 * Receives BearCapture:Download from the child with a media URL and filename.
 * Uses the toolkit Downloads API to queue a download to the user's preferred
 * download directory, so it appears in the browser's Downloads panel normally.
 */

const lazy = {};
ChromeUtils.defineESModuleGetters(lazy, {
  Downloads: "resource://gre/modules/Downloads.sys.mjs",
  FileUtils: "resource://gre/modules/FileUtils.sys.mjs",
});

export class BearCaptureParent extends JSWindowActorParent {
  async receiveMessage(msg) {
    if (msg.name !== "BearCapture:Download") return;
    const { url, filename } = msg.data;
    if (!url || typeof url !== "string") return;

    try {
      await this.#download(url, filename);
    } catch (e) {
      console.error("BearCapture: download failed", e);
    }
  }

  async #download(url, suggestedFilename) {
    const list = await lazy.Downloads.getList(lazy.Downloads.ALL);
    const targetDir = await this.#getDownloadDir();

    // Sanitize filename
    const safe = (suggestedFilename ?? "")
      .replace(/[/\\?%*:|"<>]/g, "_")
      .replace(/^\.+/, "")
      .slice(0, 200) || "media-download";

    const targetPath = PathUtils.join(targetDir, safe);

    const download = await lazy.Downloads.createDownload({
      source: { url, isPrivate: false },
      target: { path: targetPath, partFilePath: targetPath + ".part" },
    });

    await list.add(download);
    await download.start();
  }

  async #getDownloadDir() {
    try {
      return await lazy.Downloads.getPreferredDownloadsDirectory();
    } catch {
      // Fallback to ~/Downloads
      return PathUtils.join(
        Services.dirsvc.get("Home", Ci.nsIFile).path,
        "Downloads"
      );
    }
  }
}

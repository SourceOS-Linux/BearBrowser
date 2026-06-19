/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a cup of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearCaptureChild — finds media on the current page and queues downloads.
 *
 * Scans for:
 *   - <video> and <audio> elements (src / currentSrc / <source> children)
 *   - <a> links whose href ends in a known media extension
 *
 * Shows a floating badge (bottom-right, "▼ N") when media is found.
 * Clicking the badge shows an inline panel listing all sources with filenames
 * and Download buttons. Cmd+Shift+D / Ctrl+Shift+D opens the panel from
 * anywhere on the page.
 *
 * Pref: bearbrowser.capture.enabled (default true)
 */

const MEDIA_EXTS = new Set([
  "mp4","webm","mkv","m4v","avi","mov","ogv","flv",
  "mp3","ogg","opus","flac","m4a","wav","aac",
]);

function guessExt(url) {
  try {
    const path = new URL(url).pathname;
    const ext = path.split(".").pop()?.toLowerCase();
    return MEDIA_EXTS.has(ext) ? ext : "mp4";
  } catch {
    return "mp4";
  }
}

function suggestedFilename(url, title) {
  try {
    const path = new URL(url).pathname;
    const base = path.split("/").pop() || (title ?? "video");
    return base.includes(".") ? base : base + "." + guessExt(url);
  } catch {
    return "media." + guessExt(url);
  }
}

function collectMedia(doc) {
  const found = new Map(); // url → { type, filename }

  // <video> and <audio> elements
  for (const el of doc.querySelectorAll("video, audio")) {
    const src = el.currentSrc || el.src;
    if (src && !found.has(src)) {
      found.set(src, {
        type: el.tagName.toLowerCase(),
        filename: suggestedFilename(src, doc.title),
      });
    }
    for (const source of el.querySelectorAll("source")) {
      if (source.src && !found.has(source.src)) {
        found.set(source.src, {
          type: el.tagName.toLowerCase(),
          filename: suggestedFilename(source.src, doc.title),
        });
      }
    }
  }

  // <a href> links pointing to media files
  for (const a of doc.querySelectorAll("a[href]")) {
    const href = a.href;
    if (!href || found.has(href)) continue;
    try {
      const ext = new URL(href).pathname.split(".").pop()?.toLowerCase();
      if (MEDIA_EXTS.has(ext)) {
        found.set(href, {
          type: "link",
          filename: suggestedFilename(href, a.textContent.trim() || doc.title),
        });
      }
    } catch { /* ignore */ }
  }

  return Array.from(found.entries()).map(([url, meta]) => ({ url, ...meta }));
}

export class BearCaptureChild extends JSWindowActorChild {
  #enabled = false;
  #panel = null;
  #badge = null;

  actorCreated() {
    this.#enabled = Services.prefs.getBoolPref("bearbrowser.capture.enabled", true);
  }

  handleEvent(event) {
    if (!this.#enabled) return;
    if (event.type === "DOMContentLoaded" || event.type === "pageshow") {
      this.#scan();
    }
    if (event.type === "keydown") this.#onKeyDown(event);
  }

  #onKeyDown(event) {
    const isMac = Services.appinfo.OS === "Darwin";
    const mod = isMac ? event.metaKey && event.shiftKey : event.ctrlKey && event.shiftKey;
    if (!mod || event.key.toLowerCase() !== "d") return;
    event.preventDefault();
    this.#togglePanel();
  }

  #scan() {
    const items = collectMedia(this.document);
    this.#badge?.remove();
    this.#badge = null;
    if (!items.length) return;

    const doc = this.document;
    const badge = doc.createElement("div");
    Object.assign(badge.style, {
      position: "fixed",
      bottom: "20px",
      right: "20px",
      zIndex: "2147483646",
      background: "#1D9E75",
      color: "#fff",
      padding: "6px 12px",
      borderRadius: "20px",
      font: "bold 12px/1 -apple-system,sans-serif",
      cursor: "pointer",
      userSelect: "none",
      boxShadow: "0 2px 8px rgba(0,0,0,.3)",
    });
    badge.textContent = `▼ ${items.length}`;
    badge.title = `${items.length} media file${items.length > 1 ? "s" : ""} found — click to download`;
    badge.addEventListener("click", () => this.#togglePanel());
    doc.body?.appendChild(badge);
    this.#badge = badge;
  }

  #togglePanel() {
    if (this.#panel) {
      this.#panel.remove();
      this.#panel = null;
      return;
    }
    const items = collectMedia(this.document);
    if (!items.length) {
      this.#showToast("No media found on this page.");
      return;
    }
    this.#showPanel(items);
  }

  #showPanel(items) {
    const doc = this.document;
    this.#panel?.remove();

    const panel = doc.createElement("div");
    Object.assign(panel.style, {
      position: "fixed",
      bottom: "60px",
      right: "20px",
      zIndex: "2147483647",
      background: "rgba(20,20,20,.97)",
      color: "#fff",
      borderRadius: "8px",
      padding: "12px",
      width: "360px",
      maxHeight: "400px",
      overflowY: "auto",
      font: "13px/1.5 -apple-system,sans-serif",
      boxShadow: "0 4px 20px rgba(0,0,0,.5)",
    });

    const header = doc.createElement("div");
    Object.assign(header.style, {
      display: "flex",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: "10px",
      paddingBottom: "8px",
      borderBottom: "1px solid rgba(255,255,255,.1)",
    });
    header.innerHTML = `<span style="font-weight:600">BearCapture</span><span style="cursor:pointer;opacity:.6" id="bb-cap-close">✕</span>`;
    panel.appendChild(header);
    panel.querySelector("#bb-cap-close").addEventListener("click", () => {
      panel.remove();
      this.#panel = null;
    });

    for (const item of items) {
      const row = doc.createElement("div");
      Object.assign(row.style, {
        display: "flex",
        alignItems: "center",
        gap: "8px",
        padding: "6px 0",
        borderBottom: "1px solid rgba(255,255,255,.06)",
      });

      const icon = item.type === "audio" ? "♪" : "▶";
      const name = doc.createElement("div");
      name.style.cssText = "flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px;opacity:.85";
      name.title = item.filename;
      name.textContent = icon + " " + item.filename;

      const btn = doc.createElement("button");
      Object.assign(btn.style, {
        background: "#1D9E75",
        color: "#fff",
        border: "none",
        borderRadius: "4px",
        padding: "4px 10px",
        font: "12px -apple-system,sans-serif",
        cursor: "pointer",
        whiteSpace: "nowrap",
        flexShrink: "0",
      });
      btn.textContent = "Download";
      btn.addEventListener("click", () => {
        this.sendAsyncMessage("BearCapture:Download", {
          url: item.url,
          filename: item.filename,
        });
        btn.textContent = "Queued ✓";
        btn.disabled = true;
        btn.style.opacity = ".5";
      });

      row.appendChild(name);
      row.appendChild(btn);
      panel.appendChild(row);
    }

    doc.body?.appendChild(panel);
    this.#panel = panel;
  }

  #showToast(msg) {
    const doc = this.document;
    doc.querySelector("#bb-cap-toast")?.remove();
    const toast = doc.createElement("div");
    toast.id = "bb-cap-toast";
    Object.assign(toast.style, {
      position: "fixed", bottom: "60px", right: "20px", zIndex: "2147483647",
      background: "rgba(15,15,15,.9)", color: "#fff", padding: "8px 14px",
      borderRadius: "4px", font: "13px/1.5 -apple-system,sans-serif",
      pointerEvents: "none",
    });
    toast.textContent = msg;
    doc.body?.appendChild(toast);
    doc.defaultView?.setTimeout(() => toast.remove(), 2500);
  }

  didDestroy() {
    this.#panel?.remove();
    this.#badge?.remove();
  }
}

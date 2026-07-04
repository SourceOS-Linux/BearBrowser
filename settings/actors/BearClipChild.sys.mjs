/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearClipChild — extracts bibliographic metadata from the current page and
 * sends it to BearClipParent for persistence.
 *
 * Cmd+Shift+S / Ctrl+Shift+S captures the current page.
 *
 * Metadata sources (in priority order):
 *   1. <meta name="citation_*"> — Google Scholar / academic publisher standard
 *   2. Dublin Core <meta name="DC.*">
 *   3. Open Graph <meta property="og:*">
 *   4. JSON-LD <script type="application/ld+json">
 *   5. arXiv ID from URL / meta tags
 *   6. DOI from URL / meta tags / <a href="https://doi.org/...">
 *   7. Fallbacks: document.title, meta[name=description], <time>
 *
 * Pref: bearbrowser.clip.enabled (default true)
 */

function getMeta(doc, ...selectors) {
  for (const sel of selectors) {
    const el = doc.querySelector(sel);
    if (el) {
      const v = el.content ?? el.getAttribute("content") ?? el.textContent;
      if (v?.trim()) return v.trim();
    }
  }
  return null;
}

function getAllMeta(doc, name) {
  return Array.from(doc.querySelectorAll(`meta[name="${name}"]`))
    .map(el => el.getAttribute("content"))
    .filter(Boolean);
}

function extractArxivId(url) {
  const m = url.match(/arxiv\.org\/(abs|pdf)\/([0-9]{4}\.[0-9]{4,5}(v\d+)?)/i);
  return m?.[2] ?? null;
}

function extractDoi(doc, url) {
  // From URL (doi.org resolver)
  if (/doi\.org\/10\.\d{4}/.test(url)) {
    return url.replace(/.*doi\.org\//, "");
  }
  // From citation meta
  const metaDoi = getMeta(doc, 'meta[name="citation_doi"]', 'meta[name="DC.Identifier"]');
  if (metaDoi?.startsWith("10.")) return metaDoi;
  // From first doi.org link
  const doiLink = doc.querySelector('a[href*="doi.org/10."]');
  if (doiLink) return doiLink.href.replace(/.*doi\.org\//, "");
  return null;
}

function extractJsonLd(doc) {
  for (const el of doc.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      const data = JSON.parse(el.textContent);
      const obj = Array.isArray(data) ? data[0] : data;
      if (obj["@type"] && obj.name) return obj;
    } catch { /* skip */ }
  }
  return null;
}

function detectItemType(doc, url) {
  if (/arxiv\.org/.test(url)) return "preprint";
  if (/doi\.org|springer|elsevier|wiley|nature\.com|science\.org|pubmed|ncbi/.test(url)) return "journalArticle";
  if (/youtube\.com|vimeo\.com/.test(url)) return "videoRecording";
  if (/github\.com/.test(url)) return "computerProgram";
  if (getMeta(doc, 'meta[name="citation_journal_title"]')) return "journalArticle";
  if (getMeta(doc, 'meta[name="citation_conference_title"]')) return "conferencePaper";
  if (getMeta(doc, 'meta[name="citation_isbn"]')) return "book";
  return "webpage";
}

function extractClip(doc, url) {
  const ld = extractJsonLd(doc);

  const title =
    getMeta(doc, 'meta[name="citation_title"]', 'meta[name="DC.Title"]', 'meta[property="og:title"]', 'meta[name="title"]') ??
    ld?.name ??
    doc.title ??
    "";

  const authors =
    getAllMeta(doc, "citation_author").length
      ? getAllMeta(doc, "citation_author")
      : getAllMeta(doc, "DC.Creator").length
        ? getAllMeta(doc, "DC.Creator")
        : ld?.author
          ? (Array.isArray(ld.author) ? ld.author : [ld.author]).map(a => a.name ?? a)
          : [];

  const date =
    getMeta(doc, 'meta[name="citation_publication_date"]', 'meta[name="citation_date"]', 'meta[name="DC.Date"]', 'meta[property="article:published_time"]') ??
    ld?.datePublished ??
    doc.querySelector("time[datetime]")?.getAttribute("datetime") ??
    "";

  const journal = getMeta(doc, 'meta[name="citation_journal_title"]', 'meta[name="DC.Source"]') ?? "";
  const volume  = getMeta(doc, 'meta[name="citation_volume"]') ?? "";
  const issue   = getMeta(doc, 'meta[name="citation_issue"]') ?? "";
  const pages   = getMeta(doc, 'meta[name="citation_firstpage"]') ?? "";
  const isbn    = getMeta(doc, 'meta[name="citation_isbn"]', 'meta[name="DC.Identifier.ISBN"]') ?? "";
  const abstract = getMeta(doc, 'meta[name="citation_abstract"]', 'meta[name="DC.Description"]', 'meta[property="og:description"]', 'meta[name="description"]') ?? "";
  const doi     = extractDoi(doc, url);
  const arxivId = extractArxivId(url) ?? getMeta(doc, 'meta[name="citation_arxiv_id"]') ?? null;

  return {
    itemType: detectItemType(doc, url),
    title,
    url,
    authors,
    date,
    journal,
    volume,
    issue,
    pages,
    isbn,
    doi,
    arxivId,
    abstract,
    tags: [],
  };
}

export class BearClipChild extends JSWindowActorChild {
  #enabled = false;

  actorCreated() {
    this.#enabled = Services.prefs.getBoolPref("bearbrowser.clip.enabled", true);
  }

  handleEvent(event) {
    if (!this.#enabled) return;
    if (event.type === "keydown") this.#onKeyDown(event);
  }

  #onKeyDown(event) {
    const isMac = Services.appinfo.OS === "Darwin";
    const mod = isMac ? event.metaKey && event.shiftKey : event.ctrlKey && event.shiftKey;
    if (!mod || event.key.toLowerCase() !== "s") return;

    // Don't intercept normal Cmd+Shift+S (save as) if in a form
    const active = this.document?.activeElement;
    if (active?.tagName === "INPUT" || active?.tagName === "TEXTAREA") return;

    event.preventDefault();
    event.stopPropagation();
    this.#clip();
  }

  #clip() {
    const doc = this.document;
    const url = doc?.location?.href ?? "";
    if (!url) return;

    const clip = extractClip(doc, url);
    this.sendAsyncMessage("BearClip:Save", { clip });
    this.#showToast(`Clipped: ${clip.title.slice(0, 60)}${clip.title.length > 60 ? "…" : ""}`);
  }

  #showToast(msg) {
    const doc = this.document;
    doc.querySelector("#bb-clip-toast")?.remove();
    const toast = doc.createElement("div");
    toast.id = "bb-clip-toast";
    Object.assign(toast.style, {
      position: "fixed", top: "16px", left: "50%",
      transform: "translateX(-50%)",
      zIndex: "2147483647",
      background: "rgba(15,110,86,.95)",
      color: "#fff",
      padding: "9px 18px",
      borderRadius: "6px",
      font: "13px/1.5 -apple-system,sans-serif",
      pointerEvents: "none",
      whiteSpace: "nowrap",
      maxWidth: "80vw",
      overflow: "hidden",
      textOverflow: "ellipsis",
    });
    toast.textContent = msg;
    doc.body?.appendChild(toast);
    doc.defaultView?.setTimeout(() => toast.remove(), 3000);
  }
}

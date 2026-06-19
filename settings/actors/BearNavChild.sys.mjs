/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearNavChild — native keyboard navigation (Vimium-style) in content process.
 *
 * Keyboard shortcuts (inactive when focus is in an input/textarea/[contenteditable]):
 *
 *   f          Show link hints (click mode)
 *   F          Show link hints (new tab mode)
 *   Escape     Dismiss hints
 *   j / k      Scroll down / up (line)
 *   d / u      Scroll down / up (half page)
 *   g g        Scroll to top
 *   G          Scroll to bottom
 *   H          History back
 *   L          History forward
 *   r          Reload
 *   / (slash)  Focus URL bar (sends message to parent)
 *
 * Pref: bearbrowser.nav.keyboard.enabled (default true)
 */

const HINT_CHARS = "asdfjkl;ghqweruiopzxcvbnmtyASDFJKL";
const SCROLL_PX = 60;
const SCROLL_MULTIPLIER = 8;

function generateHints(count) {
  const labels = [];
  let i = 0;
  while (labels.length < count) {
    if (i < HINT_CHARS.length) {
      labels.push(HINT_CHARS[i]);
    } else {
      const first = HINT_CHARS[Math.floor(i / HINT_CHARS.length) - 1];
      const second = HINT_CHARS[i % HINT_CHARS.length];
      labels.push(first + second);
    }
    i++;
  }
  return labels;
}

function getClickTargets(doc) {
  const tags = "a,button,input[type=button],input[type=submit],[role=button],[role=link],[role=menuitem],[tabindex]";
  return Array.from(doc.querySelectorAll(tags)).filter(el => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= (doc.defaultView.innerHeight + 200);
  }).slice(0, HINT_CHARS.length * HINT_CHARS.length);
}

export class BearNavChild extends JSWindowActorChild {
  #enabled = false;
  #hintsActive = false;
  #newTab = false;
  #typed = "";
  #hintMap = new Map(); // label → element
  #overlay = null;
  #ggPending = false;
  #ggTimer = null;

  actorCreated() {
    this.#enabled = Services.prefs.getBoolPref(
      "bearbrowser.nav.keyboard.enabled",
      true
    );
  }

  handleEvent(event) {
    if (!this.#enabled) return;
    if (event.type === "keydown") this.#onKeyDown(event);
  }

  #isEditable() {
    const el = this.document?.activeElement;
    if (!el) return false;
    const tag = el.tagName?.toLowerCase();
    return (
      tag === "input" ||
      tag === "textarea" ||
      tag === "select" ||
      el.isContentEditable ||
      el.getAttribute("role") === "textbox"
    );
  }

  #onKeyDown(event) {
    const key = event.key;

    // Hints mode: intercept label keys and Escape
    if (this.#hintsActive) {
      event.preventDefault();
      event.stopPropagation();
      if (key === "Escape") {
        this.#dismissHints();
        return;
      }
      this.#typed += key;
      this.#filterHints(this.#typed);
      return;
    }

    // Don't intercept when user is typing
    if (this.#isEditable()) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;

    const win = this.document?.defaultView;
    const body = this.document?.scrollingElement ?? this.document?.body;

    switch (key) {
      case "f":
        event.preventDefault();
        this.#showHints(false);
        break;
      case "F":
        event.preventDefault();
        this.#showHints(true);
        break;
      case "j":
        event.preventDefault();
        body?.scrollBy({ top: SCROLL_PX, behavior: "smooth" });
        break;
      case "k":
        event.preventDefault();
        body?.scrollBy({ top: -SCROLL_PX, behavior: "smooth" });
        break;
      case "d":
        event.preventDefault();
        body?.scrollBy({ top: win.innerHeight * 0.5, behavior: "smooth" });
        break;
      case "u":
        event.preventDefault();
        body?.scrollBy({ top: -win.innerHeight * 0.5, behavior: "smooth" });
        break;
      case "G":
        event.preventDefault();
        body?.scrollTo({ top: body.scrollHeight, behavior: "smooth" });
        break;
      case "g":
        event.preventDefault();
        if (this.#ggPending) {
          win?.clearTimeout(this.#ggTimer);
          this.#ggPending = false;
          body?.scrollTo({ top: 0, behavior: "smooth" });
        } else {
          this.#ggPending = true;
          this.#ggTimer = win?.setTimeout(() => { this.#ggPending = false; }, 500);
        }
        break;
      case "H":
        event.preventDefault();
        win?.history.back();
        break;
      case "L":
        event.preventDefault();
        win?.history.forward();
        break;
      case "r":
        event.preventDefault();
        win?.location.reload();
        break;
      case "/":
        event.preventDefault();
        this.sendAsyncMessage("BearNav:FocusUrlBar", {});
        break;
    }
  }

  #showHints(newTab) {
    const doc = this.document;
    this.#dismissHints();
    this.#newTab = newTab;
    this.#typed = "";

    const targets = getClickTargets(doc);
    if (!targets.length) return;

    const labels = generateHints(targets.length);
    this.#hintMap.clear();

    // Inject stylesheet once
    if (!doc.querySelector("#bb-nav-style")) {
      const style = doc.createElement("style");
      style.id = "bb-nav-style";
      style.textContent = `
        .bb-hint {
          position: absolute;
          z-index: 2147483646;
          background: #ffd700;
          color: #000;
          font: bold 11px/1 monospace;
          padding: 1px 3px;
          border-radius: 2px;
          border: 1px solid #b8860b;
          pointer-events: none;
          white-space: nowrap;
          text-transform: uppercase;
        }
        .bb-hint.bb-hint-dim { opacity: .25; }
      `;
      doc.head?.appendChild(style);
    }

    const overlay = doc.createElement("div");
    overlay.id = "bb-nav-overlay";
    Object.assign(overlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "2147483645",
      pointerEvents: "none",
    });
    doc.body?.appendChild(overlay);
    this.#overlay = overlay;

    const scrollX = doc.defaultView?.scrollX ?? 0;
    const scrollY = doc.defaultView?.scrollY ?? 0;

    for (let i = 0; i < targets.length; i++) {
      const el = targets[i];
      const label = labels[i];
      const r = el.getBoundingClientRect();

      const hint = doc.createElement("span");
      hint.className = "bb-hint";
      hint.dataset.label = label;
      hint.textContent = label;
      hint.style.left = `${r.left + scrollX}px`;
      hint.style.top = `${r.top + scrollY}px`;
      overlay.appendChild(hint);

      this.#hintMap.set(label, el);
    }

    this.#hintsActive = true;
    doc.addEventListener("keydown", this, { capture: true });
  }

  #filterHints(typed) {
    const upper = typed.toUpperCase();
    let matched = null;

    for (const [label, el] of this.#hintMap) {
      const hintEl = this.#overlay?.querySelector(`[data-label="${label}"]`);
      if (!hintEl) continue;

      if (label.toUpperCase() === upper) {
        matched = el;
      } else if (label.toUpperCase().startsWith(upper)) {
        hintEl.classList.remove("bb-hint-dim");
      } else {
        hintEl.classList.add("bb-hint-dim");
      }
    }

    if (matched) {
      this.#dismissHints();
      if (this.#newTab) {
        const href = matched.href || matched.getAttribute("href");
        if (href) {
          this.document.defaultView?.open(href, "_blank", "noopener");
        }
      } else {
        matched.click();
        matched.focus?.();
      }
    }
  }

  #dismissHints() {
    this.#overlay?.remove();
    this.#overlay = null;
    this.#hintMap.clear();
    this.#hintsActive = false;
    this.#typed = "";
    this.document?.removeEventListener("keydown", this, { capture: true });
  }

  didDestroy() {
    this.#dismissHints();
    if (this.#ggTimer) this.document?.defaultView?.clearTimeout(this.#ggTimer);
  }
}

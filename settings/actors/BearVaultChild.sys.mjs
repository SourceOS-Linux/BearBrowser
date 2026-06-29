/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearVaultChild — detects login forms and fills from OS keychain.
 *
 * On pages with password fields: shows a small ⚿ badge in the top-right
 * corner of each detected password field. Cmd+Shift+L (macOS) or
 * Ctrl+Shift+L (Linux/Windows) triggers a credential lookup for the current
 * hostname via BearVaultParent, then fills username + password fields.
 *
 * Intentionally not automatic — user must explicitly invoke the fill.
 * The filled password string is nulled from JS memory after DOM assignment.
 *
 * Pref: bearbrowser.vault.enabled (default true)
 */

const FILL_KEY = "l";

export class BearVaultChild extends JSWindowActorChild {
  #enabled = false;
  #observer = null;

  actorCreated() {
    this.#enabled = Services.prefs.getBoolPref("bearbrowser.vault.enabled", true);
  }

  handleEvent(event) {
    if (!this.#enabled) return;
    if (event.type === "DOMContentLoaded" || event.type === "pageshow") {
      this.#scanForms();
    }
    if (event.type === "keydown") {
      this.#onKeyDown(event);
    }
  }

  #onKeyDown(event) {
    const isMac = Services.appinfo.OS === "Darwin";
    const modMatch = isMac
      ? event.metaKey && event.shiftKey
      : event.ctrlKey && event.shiftKey;
    if (!modMatch || event.key.toLowerCase() !== FILL_KEY) return;

    event.preventDefault();
    event.stopPropagation();
    this.#requestFill();
  }

  #scanForms() {
    const doc = this.document;
    if (!doc) return;

    this.#observer?.disconnect();
    this.#observer = new doc.defaultView.MutationObserver(() => this.#scanForms());
    this.#observer.observe(doc.body ?? doc.documentElement, {
      childList: true,
      subtree: false,
    });

    const pwFields = doc.querySelectorAll("input[type=password]");
    if (!pwFields.length) return;

    if (!doc.querySelector("#bb-vault-style")) {
      const style = doc.createElement("style");
      style.id = "bb-vault-style";
      style.textContent = `
        .bb-vault-badge {
          position: absolute;
          z-index: 2147483647;
          width: 18px; height: 18px;
          background: #1D9E75;
          border-radius: 3px;
          display: flex; align-items: center; justify-content: center;
          font-size: 11px; color: #fff;
          cursor: pointer;
          pointer-events: all;
          user-select: none;
          opacity: .85;
        }
        .bb-vault-badge:hover { opacity: 1; }
      `;
      doc.head?.appendChild(style);
    }

    const scrollX = doc.defaultView?.scrollX ?? 0;
    const scrollY = doc.defaultView?.scrollY ?? 0;

    for (const field of pwFields) {
      if (field.dataset.bbVault) continue;
      field.dataset.bbVault = "1";

      const r = field.getBoundingClientRect();
      const badge = doc.createElement("div");
      badge.className = "bb-vault-badge";
      badge.title = "Fill from OS keychain (⌘⇧L)";
      badge.textContent = "⚿";
      badge.style.left = `${r.right - 22 + scrollX}px`;
      badge.style.top = `${r.top + 2 + scrollY}px`;
      badge.addEventListener("click", () => this.#requestFill());
      doc.body?.appendChild(badge);
    }
  }

  async #requestFill() {
    const doc = this.document;
    const host = doc?.location?.hostname;
    if (!host) return;

    let cred;
    try {
      cred = await this.sendQuery("BearVault:LookupCredential", { host });
    } catch {
      this.#showToast("No credentials found in OS keychain.");
      return;
    }

    if (!cred?.password) {
      this.#showToast("No credentials found for " + host);
      return;
    }

    // Fill the first username-like field before the password field
    if (cred.username) {
      const usernameField = doc.querySelector(
        "input[type=email], input[type=text][name*=user], input[type=text][name*=login], input[type=text][name*=email]"
      );
      if (usernameField) {
        this.#fillField(usernameField, cred.username);
      }
    }

    const pwField = doc.querySelector("input[type=password]");
    if (pwField) {
      this.#fillField(pwField, cred.password);
    }

    // Null the password reference as soon as we're done
    cred.password = null;
    cred = null;

    this.#showToast("Filled from OS keychain.");
  }

  #fillField(el, value) {
    // Trigger React/Vue/Angular synthetic input events
    const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
      el.ownerGlobal.HTMLInputElement.prototype,
      "value"
    )?.set;
    nativeInputValueSetter?.call(el, value);
    el.dispatchEvent(new el.ownerGlobal.Event("input", { bubbles: true }));
    el.dispatchEvent(new el.ownerGlobal.Event("change", { bubbles: true }));
  }

  #showToast(msg) {
    const doc = this.document;
    doc.querySelector("#bb-vault-toast")?.remove();
    const toast = doc.createElement("div");
    toast.id = "bb-vault-toast";
    Object.assign(toast.style, {
      position: "fixed",
      top: "16px",
      right: "16px",
      zIndex: "2147483647",
      background: "rgba(15,15,15,.9)",
      color: "#fff",
      padding: "8px 14px",
      borderRadius: "4px",
      font: "13px/1.5 -apple-system,sans-serif",
      pointerEvents: "none",
    });
    toast.textContent = msg;
    doc.body?.appendChild(toast);
    doc.defaultView?.setTimeout(() => toast.remove(), 3000);
  }

  didDestroy() {
    this.#observer?.disconnect();
  }
}

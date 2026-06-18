/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearBlockerChild — cosmetic filter injection for BearBrowser.
 *
 * Runs in the content process for every http/https page. On DOMContentLoaded
 * it injects compiled CSS cosmetic rules that hide ad placeholders left behind
 * after network-level blocking by ContentClassifierService. A MutationObserver
 * re-applies rules for dynamically injected containers (SPA route changes, lazy
 * ad slots). Total overhead per page: one style element + one MutationObserver.
 */

const COSMETIC_CSS = `
/* BearBlocker cosmetic rules v1 */

/* Google Ads containers */
.adsbygoogle,
ins.adsbygoogle,
[data-ad-client],
[data-ad-slot],
[data-ad-unit-id],
[data-ad-format],
[data-matched-content-ui-type],

/* Common ad wrapper patterns */
.ad-container,
.ad-wrapper,
.ad-banner,
.ad-slot,
.ad-unit,
.ad-placeholder,
.ad-overlay,
.ad-leaderboard,
.ad-rectangle,
.ad-sidebar,
.ad-block,
.advertisement,
.advertisment,
.widget-advertise,
.widget-advertisement,

/* ID-based patterns */
#ad-container,
#ad-banner,
#ad-slot,
#google-ad,
#div-gpt-ad,
#div-gpt-ad-wrapper,
[id^="google_ads_iframe"],
[id^="div-gpt-ad"],
[id^="aswift_"],
[id^="ad-"],

/* Data attribute patterns */
[data-component="ad"],
[data-type="ad"],
[data-ad="true"],
[data-adunit],

/* Aria label patterns */
[aria-label="Advertisement"],
[aria-label="Sponsored Content"],
[aria-label="Ad"],

/* Sponsored content */
.sponsored,
.sponsored-content,
.sponsored-post,
[class*="SponsoredLabel"],

/* Taboola */
[id*="taboola"],
[class*="taboola"],
.trc_rbox,
.trc_rbox_div,
.trc_related_container,

/* Outbrain */
[id*="outbrain"],
[class*="outbrain"],
.OUTBRAIN,
.ob-widget,
.ob-smart-feed,

/* Sticky / interstitial overlays */
[class*="sticky-ad"],
[id*="sticky-ad"],
.sticky-advertisement,
[class*="interstitial-ad"],

/* Float-in ad units */
[class*="float-ad"],
[id*="float-ad"],

/* Newsletter signup popups injected by ad networks */
[class*="ad-notification"],
[class*="ad-popup"],

{ display: none !important; visibility: hidden !important; }
`;

const HIDDEN_CLASS = "bb-cosmetic-hidden";
const PROCESSED_ATTR = "data-bb-checked";

function injectStyle(doc) {
  if (doc.getElementById("bb-cosmetic-style")) {
    return;
  }
  const style = doc.createElement("style");
  style.id = "bb-cosmetic-style";
  style.textContent = COSMETIC_CSS;
  (doc.head || doc.documentElement).appendChild(style);
}

function isEnabled() {
  try {
    return Services.prefs.getBoolPref(
      "bearbrowser.bearblocker.cosmetic.enabled",
      true
    );
  } catch {
    return true;
  }
}

export class BearBlockerChild extends JSWindowActorChild {
  #observer = null;

  handleEvent(event) {
    if (!isEnabled()) {
      return;
    }
    const doc = event.target;
    if (!doc || doc.nodeType !== Node.DOCUMENT_NODE) {
      return;
    }
    if (
      event.type === "DOMContentLoaded" ||
      event.type === "pageshow"
    ) {
      this.#applyCosmetic(doc);
    }
  }

  #applyCosmetic(doc) {
    injectStyle(doc);
    this.#startObserver(doc);
    this.sendAsyncMessage("BearBlocker:CosmeticApplied", {
      url: doc.location?.href ?? "",
    });
  }

  #startObserver(doc) {
    if (this.#observer) {
      return;
    }
    this.#observer = new doc.defaultView.MutationObserver(mutations => {
      for (const mutation of mutations) {
        if (mutation.type === "childList" && mutation.addedNodes.length) {
          injectStyle(doc);
          break;
        }
      }
    });
    this.#observer.observe(doc.body || doc.documentElement, {
      childList: true,
      subtree: false,
    });
  }

  didDestroy() {
    this.#observer?.disconnect();
    this.#observer = null;
  }
}

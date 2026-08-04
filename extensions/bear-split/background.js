// MIT License — BearBrowser Bear Split
// Opens the current tab in a side-by-side split view.
"use strict";

function openSplit(currentUrl) {
  const base = browser.runtime.getURL("split.html");
  const url  = base
    + "?left="  + encodeURIComponent(currentUrl || "about:blank")
    + "&right=" + encodeURIComponent("about:blank");
  browser.tabs.create({ url });
}

browser.commands.onCommand.addListener((cmd) => {
  if (cmd === "open-split") {
    browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
      openSplit(tab ? tab.url : "about:blank");
    });
  }
});

browser.browserAction.onClicked.addListener((tab) => {
  openSplit(tab ? tab.url : "about:blank");
});

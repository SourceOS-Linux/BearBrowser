// BearBrowser start page wiring — appended to bearbrowser.cfg (autoconfig).
// NOTE: autoconfig .cfg files SKIP THEIR FIRST LINE, so when this file becomes
// the whole cfg (macOS post-package injection) the leading comment above is the
// sacrificial line. When appended to the generated cfg (Linux/Windows overlay
// path) position doesn't matter.
//
// There is no pref for the new-tab URL in modern Firefox — the supported
// mechanism is setting AboutNewTab.newTabURL from privileged autoconfig JS
// (requires general.config.sandbox_enabled=false, set in local-settings.js).
// Wrapped so a failure can never break browser startup.
try {
  if (!Services.appinfo.inSafeMode) {
    const { AboutNewTab } = ChromeUtils.importESModule(
      "resource:///modules/AboutNewTab.sys.mjs"
    );
    AboutNewTab.newTabURL = "resource:///bearstart/bearbrowser-start.html";
  }
} catch (e) {
  // Leave stock about:newtab in place rather than risk startup.
}

// ── BearNet entry points ────────────────────────────────────────────────────
// Make the network monitor reachable from ANYWHERE, not just the new-tab tile:
// a persistent nav-bar button (always visible, cross-platform), a Tools-menu
// item, and a Ctrl/Cmd+Alt+N shortcut. All best-effort — never break startup.
try {
  if (!Services.appinfo.inSafeMode) {
    const BEARNET_URL = "resource:///bearstart/bearnet.html";
    // Small radar glyph, themed to the toolbar's text color.
    const ICON =
      "data:image/svg+xml," +
      encodeURIComponent(
        "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 16 16' fill='none' stroke='context-fill' stroke-width='1.3'>" +
          "<circle cx='8' cy='8' r='1.6' fill='context-fill' stroke='none'/>" +
          "<circle cx='8' cy='8' r='4'/><circle cx='8' cy='8' r='6.6'/>" +
          "<circle cx='13' cy='4' r='1.1' fill='context-fill' stroke='none'/>" +
        "</svg>"
      );

    const { CustomizableUI } = ChromeUtils.importESModule(
      "resource:///modules/CustomizableUI.sys.mjs"
    );
    try {
      CustomizableUI.createWidget({
        id: "bearnet-button",
        label: "BearNet",
        tooltiptext: "BearNet — see and block what this browser is talking to",
        defaultArea: CustomizableUI.AREA_NAVBAR,
        onCreated(node) {
          node.style.listStyleImage = "url('" + ICON + "')";
          node.style.MozContextProperties = "fill";
        },
        onCommand(ev) {
          ev.target.ownerGlobal.openTrustedLinkIn(BEARNET_URL, "tab");
        },
      });
    } catch (e) {
      // Widget already registered this session — fine.
    }

    // Per-window: Tools-menu item + keyboard shortcut.
    const decorate = (win) => {
      try {
        const doc = win.document;
        if (doc.documentElement.getAttribute("windowtype") !== "navigator:browser") return;
        const tools = doc.getElementById("menu_ToolsPopup");
        if (tools && !doc.getElementById("bearnet-menuitem")) {
          const mi = doc.createXULElement("menuitem");
          mi.id = "bearnet-menuitem";
          mi.setAttribute("label", "Network Monitor (BearNet)");
          mi.setAttribute("accesskey", "N");
          mi.addEventListener("command", () => win.openTrustedLinkIn(BEARNET_URL, "tab"));
          tools.insertBefore(mi, tools.firstChild);
        }
        const keyset = doc.getElementById("mainKeyset");
        if (keyset && !doc.getElementById("bearnet-key")) {
          const key = doc.createXULElement("key");
          key.id = "bearnet-key";
          key.setAttribute("key", "N");
          key.setAttribute("modifiers", "accel,alt");
          key.setAttribute(
            "oncommand",
            "openTrustedLinkIn('" + BEARNET_URL + "','tab')"
          );
          keyset.appendChild(key);
        }
      } catch (e) {}
    };
    const en = Services.wm.getEnumerator("navigator:browser");
    while (en.hasMoreElements()) decorate(en.getNext());
    Services.wm.addListener({
      onOpenWindow(xw) {
        try {
          const win = xw.docShell.domWindow;
          win.addEventListener("load", () => decorate(win), { once: true });
        } catch (e) {}
      },
      onCloseWindow() {},
      onWindowTitleChange() {},
    });
  }
} catch (e) {
  // No entry points rather than a broken browser.
}

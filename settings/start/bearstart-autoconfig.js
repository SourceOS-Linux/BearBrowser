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

// ── resource://bearstart/ substitution ──────────────────────────────────────
// CRITICAL: our start page + BearNet panel are staged LOOSE in the app at
// <GreD>/browser/bearstart/. `resource:///bearstart/` does NOT resolve to that
// (it reads from omni.ja, where FINAL_TARGET_FILES never lands + mach package
// drops it) — verified against a real DMG: the branded new-tab was shipping
// BROKEN. Register an explicit resource://bearstart/ → that dir so every
// bearstart URL resolves regardless of packaging. MUST run before anything
// below uses a bearstart URL.
try {
  const rp = Services.io
    .getProtocolHandler("resource")
    .QueryInterface(Ci.nsIResProtocolHandler);
  const dir = Services.dirsvc.get("GreD", Ci.nsIFile);
  dir.append("browser");
  dir.append("bearstart");
  if (dir.exists()) {
    rp.setSubstitution("bearstart", Services.io.newFileURI(dir));
  }
} catch (e) {}

// ── resource://bearblocker/ substitution ─────────────────────────────────────
// SAME packaging trap as bearstart, hit by the ad/tracker blocker: the filter
// lists are staged loose at <GreD>/browser/bearblocker/, but the C++
// ContentClassifierService loads them from the pref
// `privacy.trackingprotection.content.protection.test_list_urls` — which pointed
// at resource:///bearblocker/… (empty host = omni.ja, where FINAL_TARGET_FILES
// never lands). Verified on a real build: the console logged
//   "Missing chrome or resource URL: resource:///bearblocker/bearblocker-ads.txt"
// i.e. the blocker shipped with NO lists. autoconfig runs during pref-service
// init — before the classifier loads — so register resource://bearblocker/ →
// the loose dir here, and the prefs (user.js) use resource://bearblocker/.
try {
  const rpb = Services.io
    .getProtocolHandler("resource")
    .QueryInterface(Ci.nsIResProtocolHandler);
  const bdir = Services.dirsvc.get("GreD", Ci.nsIFile);
  bdir.append("browser");
  bdir.append("bearblocker");
  if (bdir.exists()) {
    rpb.setSubstitution("bearblocker", Services.io.newFileURI(bdir));
  }
} catch (e) {}

// ── Launch the BearNet capture sidecar on startup ───────────────────────────
// This is what makes BearNet LIVE instead of a paper tiger: spawn the bundled
// loopback sidecar so the panel has a data feed. Staged at <GreD>/sidecars/,
// governed by <GreD>/scripts/agent-control-bridge.py, geo DBs at <GreD>/geoip/.
// Best-effort — the panel degrades honestly to "offline" if this fails.
try {
  if (!Services.appinfo.inSafeMode) {
    const { Subprocess } = ChromeUtils.importESModule(
      "resource://gre/modules/Subprocess.sys.mjs"
    );
    const greD = Services.dirsvc.get("GreD", Ci.nsIFile);
    const geo = greD.clone();
    geo.append("geoip");
    // Unix binary or the Windows .exe, whichever was staged.
    let bin = null;
    for (const name of ["bearbrowser-capture-sidecar-bin", "bearbrowser-capture-sidecar-bin.exe"]) {
      const f = greD.clone();
      f.append("sidecars");
      f.append(name);
      if (f.exists()) { bin = f; break; }
    }
    if (bin) {
      Subprocess.call({
        command: bin.path,
        arguments: ["--repo-root", greD.path, "--port", "8093"],
        environmentAppend: true,
        environment: { CAPTURE_SIDECAR_GEOIP: geo.path },
        stderr: "stdout",
      }).catch(() => {});
    }
  }
} catch (e) {}

// ── Sovereign cockpit: resource://bearbrowser-cockpit/ + governed backend ───
// Pieces 2-4 of docs/cockpit-browser-integration-handoff.md. Everything below is
// GATED on the cockpit actually being staged (scripts/stage-cockpit.sh); if it
// is not, nothing here runs and the browser keeps the bearstart new-tab. That
// keeps a browser without an assembled cockpit completely unaffected.
//
// Topology (loopback only, no off-device egress):
//   cockpit  ──fetch──►  gate 127.0.0.1:8080  ──classify──►  agent-machine :8091
//                                                            receipts      :8092
// The cockpit must NEVER reach the sidecar directly — every agent action is
// classified by the gate against policy/bearbrowser-contract.yaml first.
//
// Ports are the fixed ones from the handoff, so no config rewriting is needed:
// the app dir can be read-only (a mounted DMG, /Applications), which is exactly
// where the `sed the live port into cockpit-config.js` approach would fail.
try {
  if (!Services.appinfo.inSafeMode) {
    const greD = Services.dirsvc.get("GreD", Ci.nsIFile);
    const ck = greD.clone();
    ck.append("cockpit");

    if (ck.exists() && ck.isDirectory()) {
      // (2) Serve the UI from a resource:// origin — same mechanism verified
      // working for bearstart. No localhost origin for the UI itself.
      try {
        const rpc = Services.io
          .getProtocolHandler("resource")
          .QueryInterface(Ci.nsIResProtocolHandler);
        rpc.setSubstitution("bearbrowser-cockpit", Services.io.newFileURI(ck));
      } catch (e) {}

      // (3) Bring up the governed backend. Gate FIRST — if the gate is not
      // listening, the cockpit simply cannot reach the sidecar, which is the
      // correct failure mode for a governed system (closed, not open).
      try {
        const { Subprocess } = ChromeUtils.importESModule(
          "resource://gre/modules/Subprocess.sys.mjs"
        );
        const scripts = greD.clone(); scripts.append("scripts");
        const policy = greD.clone(); policy.append("policy");

        const runPy = (name, args) => {
          const f = scripts.clone(); f.append(name);
          if (!f.exists()) return;
          Subprocess.call({
            command: "/usr/bin/env",
            arguments: ["python3", f.path, ...args],
            environmentAppend: true,
            environment: {
              BEARBROWSER_RESOURCES: greD.path,
              BEARBROWSER_POLICY: policy.path,
            },
            stderr: "stdout",
          }).catch(() => {});
        };

        // agent-machine sidecar (the compiled backend), then receipts, then the
        // gate that fronts them.
        let am = null;
        for (const n of ["bearbrowser-agent-machine-bin", "bearbrowser-agent-machine-bin.exe"]) {
          const f = greD.clone(); f.append("sidecars"); f.append(n);
          if (f.exists()) { am = f; break; }
        }
        if (am) {
          Subprocess.call({
            command: am.path,
            arguments: ["--port", "8091", "--host", "127.0.0.1"],
            environmentAppend: true,
            stderr: "stdout",
          }).catch(() => {});
        }
        runPy("bearbrowser-receipts.py", ["--port", "8092"]);
        runPy("bearbrowser-agent-machine-gate.py",
              ["--port", "8080", "--upstream", "http://127.0.0.1:8091"]);
      } catch (e) {}

      // (4) The browser shell IS the cockpit: new tab opens it instead of the
      // bearstart page. Only when the cockpit is present, so this never leaves
      // a cockpit-less build with a broken new-tab.
      try {
        const { AboutNewTab } = ChromeUtils.importESModule(
          "resource:///modules/AboutNewTab.sys.mjs"
        );
        // Point at the waiter, not the cockpit itself. The waiter polls the
        // gate's /health and forwards to the cockpit only once the backend is
        // bound. Fixes the cockpit-startup race where new-tab opened before
        // the gate had a chance to listen.
        AboutNewTab.newTabURL = "resource://bearstart/cockpit-waiter.html";
      } catch (e) {}
    }
  }
} catch (e) {}

// ── Sovereign update check (once/week, one request, no per-install fingerprint) ──
// We killed aus5.mozilla.org because it phones home %OS_VERSION%/%BUILD_TARGET%/
// %LOCALE% per install. Our version: fetch a static latest.json from the release
// page ONCE PER WEEK, compare, notify via observer if newer. No auto-download.
// One GitHub HTTPS request per user per week, no fingerprint-bearing template.
try {
  const LAST_KEY = "bearbrowser.update.last_check";
  const WEEK_MS = 7 * 24 * 3600 * 1000;
  const last = Services.prefs.getIntPref(LAST_KEY, 0);
  const now = Math.floor(Date.now() / 1000);
  if (now - last > WEEK_MS / 1000) {
    Services.prefs.setIntPref(LAST_KEY, now);
    // 30s delay so this never adds to startup latency
    setTimeout(() => {
      fetch("https://github.com/SourceOS-Linux/BearBrowser/releases/latest/download/latest.json",
            { cache: "no-store",
              credentials: "omit",          // never send GitHub any cookie
              referrer: "",                 // no Referer header at all
              referrerPolicy: "no-referrer" })
        .then(r => r.ok ? r.json() : null)
        .then(m => {
          if (!m || !m.version) return;
          const here = Services.appinfo.version;
          // Robust integer parse — "150.0.4-rc1" becomes [150,0,4], not [150,0,NaN].
          const parse = v => String(v).split(".").map(p => parseInt(p, 10) || 0);
          const cmp = parse(m.version);
          const cur = parse(here);
          for (let i = 0; i < Math.max(cmp.length, cur.length); i++) {
            const a = cmp[i] || 0, b = cur[i] || 0;
            if (a > b) {
              Services.obs.notifyObservers(
                { wrappedJSObject: { available: m.version, current: here, url: m.release_url } },
                "bearbrowser-update-available"
              );
              return;
            }
            if (a < b) return;
          }
        })
        .catch(() => {}); // offline, GitHub down, etc. — silent, no retry storm
    }, 30000);
  }
} catch (e) {}

// ── BearTrap network monitor ────────────────────────────────────────────────
// Start the honeypot's outbound-traffic watcher early so it's live before any
// request — it cancels any request that leaks a page's own canary token.
try {
  if (!Services.appinfo.inSafeMode) {
    const { BearTrapMonitor } = ChromeUtils.importESModule(
      "resource:///actors/BearTrapMonitor.sys.mjs"
    );
    BearTrapMonitor.start();
  }
} catch (e) {}

try {
  if (!Services.appinfo.inSafeMode) {
    const { AboutNewTab } = ChromeUtils.importESModule(
      "resource:///modules/AboutNewTab.sys.mjs"
    );
    AboutNewTab.newTabURL = "resource://bearstart/bearbrowser-start.html";
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
    const BEARNET_URL = "resource://bearstart/bearnet.html";
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

    // Badge the BearNet button when BearTrap catches fingerprinting OR when
    // BearWall blocks a vendor host — so the honeypot + firewall are visible
    // from anywhere, not just inside the panel. Total count on tooltip; the
    // per-kind counts show up on the BearTrap surface page.
    try {
      const fpOrigins = new Set();      // fingerprint probe origins seen
      const vendorHosts = new Set();    // BearWall-blocked hosts seen
      const canaryOrigins = new Set();  // canary-token exfiltration origins
      const summary = () => {
        const bits = [];
        if (fpOrigins.size)    bits.push(fpOrigins.size    + " fingerprint attempt"     + (fpOrigins.size    === 1 ? "" : "s"));
        if (vendorHosts.size)  bits.push(vendorHosts.size  + " vendor request"          + (vendorHosts.size  === 1 ? "" : "s") + " blocked");
        if (canaryOrigins.size) bits.push(canaryOrigins.size + " canary exfiltration"   + (canaryOrigins.size === 1 ? "" : "s"));
        return bits.length ? bits.join(", ") + " — open BearTrap" : "BearNet — see and block what this browser is talking to";
      };
      const total = () => fpOrigins.size + vendorHosts.size + canaryOrigins.size;
      Services.obs.addObserver(
        {
          observe(subj) {
            try {
              const d = subj && subj.wrappedJSObject;
              if (!d) return;
              if (d.kind === "fingerprint"    && d.origin) fpOrigins.add(d.origin);
              if (d.kind === "vendor-blocked" && (d.dest || d.host)) vendorHosts.add(d.dest || d.host);
              if (d.kind === "canary"         && d.origin) canaryOrigins.add(d.origin);
              const n = total();
              const active = fpOrigins.size + vendorHosts.size + canaryOrigins.size > 0;
              const e2 = Services.wm.getEnumerator("navigator:browser");
              while (e2.hasMoreElements()) {
                const b = e2.getNext().document.getElementById("bearnet-button");
                if (b) {
                  b.setAttribute("tooltiptext", summary());
                  b.setAttribute("beartrap", active ? "1" : "0");
                  b.setAttribute("data-block-count", String(n));
                }
              }
            } catch (e) {}
          },
        },
        "beartrap-detection",
        false
      );
    } catch (e) {}
  }
} catch (e) {
  // No entry points rather than a broken browser.
}

// ── BearBrowser appMenu (hamburger) section ────────────────────────────────
// The classic macOS Tools menu is niche — the hamburger appMenu is where every
// Windows/Linux user + most macOS users actually find things. Adding a
// BearBrowser subsection here surfaces BearNet, BearTrap, BearWall and the
// Cockpit at the top-level flat menu, so they are reachable without knowing
// resource:// URLs.
//
// Injection strategy: the appMenu is lazy-loaded; the panel's main view
// (#appMenu-mainView) only exists after the panel opens once. Observing the
// panel's `ViewShowing` event catches the first open reliably, and re-adds
// on subsequent opens if a customize wipe removed our nodes.
try {
  if (!Services.appinfo.inSafeMode) {
    const ENTRIES = [
      { id: "bearbrowser-appmenu-bearnet",    label: "BearNet — Network Monitor",  url: "resource://bearstart/bearnet.html",             accessKey: "N" },
      { id: "bearbrowser-appmenu-beartrap",   label: "BearTrap — Fingerprint Log", url: "resource://bearstart/beartrap.html#beartrap",   accessKey: "T" },
      { id: "bearbrowser-appmenu-bearwall",   label: "BearWall — Blocked Vendors", url: "resource://bearstart/beartrap.html#bearwall",   accessKey: "W" },
      { id: "bearbrowser-appmenu-cockpit",    label: "Cockpit",                    url: "resource://bearbrowser-cockpit/index.html",     accessKey: "C" },
    ];
    const ensureAppMenuSection = (win) => {
      try {
        const doc = win.document;
        if (doc.documentElement.getAttribute("windowtype") !== "navigator:browser") return;
        const view = doc.getElementById("appMenu-mainView");
        if (!view) return;
        const body = view.querySelector(".panel-subview-body") || view;
        // Separator marks the start of our section — presence == already inserted.
        if (doc.getElementById("bearbrowser-appmenu-separator")) return;
        const sep = doc.createXULElement("toolbarseparator");
        sep.id = "bearbrowser-appmenu-separator";
        body.insertBefore(sep, body.firstChild);
        for (let i = ENTRIES.length - 1; i >= 0; i--) {
          const e = ENTRIES[i];
          if (doc.getElementById(e.id)) continue;
          const btn = doc.createXULElement("toolbarbutton");
          btn.id = e.id;
          btn.className = "subviewbutton subviewbutton-iconic";
          btn.setAttribute("label", e.label);
          btn.setAttribute("accesskey", e.accessKey);
          btn.addEventListener("command", () => {
            try {
              win.PanelUI && win.PanelUI.hide && win.PanelUI.hide();
              win.openTrustedLinkIn(e.url, "tab");
            } catch (err) {}
          });
          body.insertBefore(btn, sep.nextSibling);
        }
      } catch (e) {}
    };
    const armPerWindow = (win) => {
      try {
        // Try immediately, in case the panel has been opened before.
        ensureAppMenuSection(win);
        // Re-arm on every open so a Customize-reset doesn't strand our items.
        const panel = win.document.getElementById("appMenu-popup");
        if (panel && !panel.hasAttribute("bearbrowser-hooked")) {
          panel.setAttribute("bearbrowser-hooked", "1");
          panel.addEventListener("ViewShowing", () => ensureAppMenuSection(win));
        }
      } catch (e) {}
    };
    const en = Services.wm.getEnumerator("navigator:browser");
    while (en.hasMoreElements()) armPerWindow(en.getNext());
    Services.wm.addListener({
      onOpenWindow(xw) {
        try {
          const win = xw.docShell.domWindow;
          win.addEventListener("load", () => armPerWindow(win), { once: true });
        } catch (e) {}
      },
      onCloseWindow() {},
      onWindowTitleChange() {},
    });
  }
} catch (e) {
  // appMenu injection is best-effort — the nav-bar button + Tools menu are the
  // primary paths; hamburger is nice-to-have.
}

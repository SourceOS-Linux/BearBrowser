# BearBrowser Bundled Extensions

Two first-party extensions ship bundled with every BearBrowser build.
They are force-installed at first launch via enterprise policy — no manual
installation required.

---

## Bear Spaces (`bear-spaces@bearbrowser.local`)

**Tab workspaces for BearBrowser.** Organises open tabs into named, persistent
workspaces (similar to Arc Spaces). Each workspace maintains its own tab set;
switching workspaces hides the current set and reveals the selected one without
closing any tabs.

Permissions: `tabs`, `tabHide`, `storage`, `contextMenus`, `nativeMessaging`.

---

## Bear Containers (`bear-containers@mdheller`)

**Multi-account container isolation.** Each container gets its own cookie jar,
localStorage, IndexedDB, and network cache, preventing cross-site tracking and
enabling simultaneous sessions under different identities (work, personal, research,
etc.) in the same browser window.

Permissions: `cookies`, `tabs`, `storage`, `contextMenus`, `webRequest`,
`webRequestBlocking`, `contextualIdentities`, `<all_urls>`.

---

## Development: loading via about:debugging

To iterate on an extension without running a full overlay build:

1. Open BearBrowser and navigate to `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on...**.
3. Select the `manifest.json` inside the extension directory
   (`extensions/bear-spaces/manifest.json` or `extensions/bear-containers/manifest.json`).
4. The extension loads for the current session.  It is removed on restart.

For persistent dev loads without a full build, create a developer profile and
add the extension to it directly.

---

## How bundling works in the overlay build

During `scripts/bearbrowser-overlay-binary.sh` (step 7/10):

1. **`scripts/bearbrowser-pack-extensions.sh`** zips each directory under
   `extensions/` into a `.xpi` named by its gecko ID and writes the files to
   `build/extensions/`.

2. **`scripts/bearbrowser-install-extensions.sh`** copies the `.xpi` files into
   `BearBrowser.app/Contents/Resources/distribution/extensions/` and merges the
   following into `distribution/policies.json`:
   - `Extensions.Install` — the `file://` URLs of each `.xpi`
   - `ExtensionSettings.<gecko-id>.installation_mode = "force_installed"` — so
     the extensions install silently even though the wildcard policy blocks
     user-initiated installs

On first browser launch the enterprise policy engine installs both extensions
automatically.  No user action is required.

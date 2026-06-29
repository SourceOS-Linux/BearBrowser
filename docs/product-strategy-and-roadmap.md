# BearBrowser Product Strategy and Roadmap

BearBrowser is a private, local-first, agent-governed browser for humans and agents.

It must not become a cosmetic fork. The product target is a browser whose runtime, credentials, memory, automation, downloads, extensions, and agent actions are governed by explicit policy and observable provenance.

## Current State

BearBrowser has crossed from specification into a dogfoodable product surface.

Implemented today:

- Homebrew-installable CLI tooling through `SourceOS-Linux/tap/bearbrowser`.
- Upstream LibreWolf source mirror for parity tracking.
- Overlay generation path for human-secure and agent-runtime profiles.
- Upstream parity verification.
- Runtime dependency policy verification.
- Credential broker policy and macOS/Linux backend manifests.
- Linux packaging metadata and sandbox skeletons.
- Native macOS `/Applications/BearBrowser.app` bootstrap shell.
- Native WebKit bootstrap window so the foreground process and Dock identity can be BearBrowser.
- Operator commands for app state: `bearbrowser-open`, `bearbrowser-status`, and `bearbrowser-reset-bootstrap`.

Not yet complete:

- Real Gecko/LibreWolf-derived BearBrowser runtime build.
- Fully branded Gecko runtime with BearBrowser application identity.
- Signed/notarized macOS distribution.
- Windows distribution.
- Production extension governance.
- First-class agent sidecar UI.
- Full provenance event stream and PolicyFabric decision adapter.

## Lessons from Chrome

Chrome sets the baseline for reliability, compatibility, sandboxing, update discipline, and process isolation.

BearBrowser must match or exceed the following product properties:

- Fast startup and predictable tab behavior.
- Site isolation and process boundaries where the engine supports them.
- Safe extension permission posture.
- Boringly reliable auto-update/update-check behavior.
- Clear download handling and unsafe-file warnings.
- DevTools compatibility for developers and agent-debugging workflows.

The Chrome lesson is not to copy Google integration. The lesson is that users forgive almost nothing in browser reliability.

## Lessons from Safari

Safari sets the baseline for platform-native trust and user experience.

BearBrowser should learn from Safari by avoiding browser-owned secret silos where the operating system already provides superior primitives.

Product principles:

- Use platform keychains and passkeys by default.
- Support biometric/device-owner unlock as an OS-mediated allow/deny decision.
- Do not expose biometric material to the browser.
- Do not build an independent password or payment vault by default.
- Treat energy use, native app identity, and system integration as first-class product quality.

## Lessons from Agentic Browsers

Agentic browsing only works if authority is explicit.

BearBrowser should learn from Atlas-style agentic browsing, but avoid opaque browser/cloud authority.

Required product rules:

- Page visibility must be explicit.
- Tab sharing must be explicit.
- Memory writes must be previewable and revocable.
- Logged-in agent actions require stronger gates than logged-out browsing.
- Sensitive sites require extra hold points.
- Agents cannot inherit human credentials by default.
- Agents cannot silently download, upload, install, purchase, or submit credentials.

## Product Positioning

BearBrowser should be positioned as:

> A governed, local-first browser where humans and agents can browse, reason, and act under explicit policy, provenance, and credential boundaries.

This differs from common browser strategies:

- Not ad-tech subsidized.
- Not cloud-memory first.
- Not a password vault.
- Not an automation wrapper with ambient authority.
- Not a cosmetic privacy fork.

## Product Pillars

### 1. Runtime Integrity

The real browser runtime must be Gecko/LibreWolf-derived until a better engine strategy is justified.

Required capabilities:

- BearBrowser-branded app identity.
- BearBrowser profile defaults.
- BearBrowser application IDs and bundle IDs.
- Upstream parity checks.
- Patch stack hashing.
- Release metadata.
- Runtime build reproducibility notes.
- Human-secure and agent-runtime profiles.

### 2. Credential Boundary

Human credentials remain user-mediated and platform-native.

Agent credentials are:

- Session-scoped.
- Policy-brokered.
- Never inherited from the human profile by default.
- Never logged as secret values.
- Revocable.

### 3. Policy and Provenance

Every privileged action needs a policy decision and an event.

Minimum event classes:

- Navigation requested.
- Navigation committed.
- Tab created or closed.
- Page shared with agent.
- Credential access requested.
- Autofill requested.
- Download requested.
- Upload requested.
- Clipboard read/write requested.
- Extension capability used.
- Agent observation performed.
- Agent mutation requested.
- Agent action approved or denied.
- Memory candidate created.
- Memory committed or rejected.

### 4. Agentic UX

Agent UX must be governed, visible, and interruptible.

Required modes:

- Observe.
- Summarize current page.
- Compare selected tabs.
- Draft form fill.
- Act with approval.
- Logged-out task mode.
- Logged-in task mode with elevated holds.
- High-risk hold.

### 5. Linux-First Distribution

Linux is not secondary.

Required Linux lanes:

- Runtime tarball.
- AppImage.
- DEB.
- RPM.
- Flatpak.
- Desktop metadata.
- AppStream metadata.
- Seccomp profile.
- AppArmor profile.
- SELinux policy skeleton.
- Secret Service/KWallet integration notes.

macOS remains a dogfood and distribution target. Windows/Chocolatey is deferred until the Linux and macOS product lanes are stable.

## Near-Term Roadmap

### Phase 1: Stabilize Product Shell

Status: in progress.

Deliverables:

- Native BearBrowser macOS shell.
- BearBrowser app identity in Dock/menu bar.
- Operator commands:
  - `bearbrowser-open`
  - `bearbrowser-status`
  - `bearbrowser-reset-bootstrap`
- Launcher logs.
- Visible engine marker.
- Clear distinction between bootstrap shell and real runtime.

### Phase 2: Real Gecko Runtime

Status: next critical path.

Deliverables:

- Compile or package a real BearBrowser runtime from the mirrored upstream source.
- Apply BearBrowser branding overlays.
- Verify no product-surface LibreWolf branding remains.
- Produce runtime tree before artifact signing.
- Emit release metadata.
- Make `bearbrowser-build-binary` progress from dry-run to generated runtime tree.

### Phase 3: Governance Event Plane

Deliverables:

- Local event stream, likely JSONL first and SQLite next.
- Event schema for navigation, downloads, credentials, automation, and memory.
- Policy decision IDs in event records.
- Redaction enforcement.
- AgentPlane capability mapping.

### Phase 4: Agent Sidecar

Deliverables:

- Current page summary.
- Selected tab comparison.
- Action proposal UI.
- Approval/deny controls.
- Memory candidate preview.
- PolicyFabric decision surface.

### Phase 5: Linux Packaging

Deliverables:

- Working Linux runtime packaging.
- AppImage and tarball first.
- DEB/RPM second.
- Flatpak third.
- Desktop and AppStream metadata validation.

### Phase 6: Signed macOS and Windows

Deferred until the real runtime and governance MVP are stable.

## Immediate Engineering Priority

The next engineering move is not more launcher polish unless the shell regresses.

The priority order is:

1. Verify the native BearBrowser WebKit shell is now the visible foreground app.
2. Add build/runtime tree generation for the real Gecko-derived runtime.
3. Add provenance event schema and local event writing.
4. Add basic agent sidecar surfaces.
5. Promote Linux runtime packaging.

## Product Quality Bar

BearBrowser becomes serious only when the following are simultaneously true:

- Installs with one command.
- Opens as BearBrowser.
- Uses BearBrowser identity everywhere visible.
- Maintains upstream security parity.
- Emits policy/provenance events for privileged actions.
- Does not silently inherit human credentials into agent runtime.
- Gives users a useful agentic browsing experience without opaque authority.
- Has a credible Linux-first packaging path.

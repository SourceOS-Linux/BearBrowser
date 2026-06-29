# Security

BearBrowser is a LibreWolf-derived SourceOS browser product for humans and agents. It has two primary execution modes: Human Secure Browser and Agent Browser Runtime.

Browser automation is privileged local authority. It can operate authenticated browser sessions, fetch web content, download files, upload files, inspect DOM state, and bridge web content into local workspaces. BearBrowser must therefore treat Playwright, Stagehand, CDP-like control, terminal-browser compatibility, downloads, profiles, and workspace mounts as governed trust surfaces.

## Current posture

BearBrowser declares its current authority in `TRUST_SURFACE.yaml`.

Default posture:

- no persistent background service by default;
- no non-loopback plaintext automation endpoint;
- no browser automation listener unless explicitly declared;
- no credential storage owned by BearBrowser by default;
- no SSH-agent inheritance;
- no shell execution by default;
- no host workspace mounts unless declared;
- no model-provider credentials;
- human browsing and agent browsing remain separate modes;
- agent runtime automation requires policy admission.

## Blocking rule

Block changes that introduce any of the following without updating `TRUST_SURFACE.yaml`:

- CDP, Playwright, Stagehand, WebSocket, HTTP, SSE, MCP, ACP, noVNC, dashboard, or browser relay listeners;
- non-loopback browser automation;
- persistent services, LaunchAgents, LaunchDaemons, systemd units, scheduled tasks, or login items;
- credential storage, OAuth, cookies/session export, keychain access, API keys, SecretRefs, SSH-agent use, or model-provider tokens;
- downloads or workspace mounts that cross from web content into agent workspaces;
- shell, terminal, extension, plugin, or native messaging execution authority;
- automatic update, direct installer, formula, cask, or runtime download behavior without provenance controls;
- diagnostics, traces, logs, crash reports, profile exports, or automation reports that expose auth/session material.

## Required local commands

BearBrowser should provide or map:

```text
scripts/doctor
scripts/network-surface
scripts/credential-surface
scripts/policy-surface
scripts/purge
scripts/prove-clean
```

These may delegate to product commands such as:

```text
bearbrowser-doctor
bearbrowser-verify-upstream
bearbrowser-automation-surfaces
```

## Cleanup and revocation

Uninstall must remove authority, not just binaries.

`prove-clean` must verify no BearBrowser process, launch item, automation listener, credential store, browser profile residue, cache, log, Application Support directory, or automation service remains unless the user explicitly chooses to retain browser state.

## Upstream discipline

SourceOS product behavior belongs in this overlay repository. The clean upstream mirror must remain clean. Any privacy, automation, policy, packaging, or agent-runtime behavior must be explicit here and declared in `TRUST_SURFACE.yaml`.

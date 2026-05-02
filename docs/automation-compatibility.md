# BearBrowser Automation Compatibility

BearBrowser has three first-class automation surfaces:

1. **Playwright control plane** — deterministic browser control, tests, replayable workflows, and cross-browser compatibility.
2. **Stagehand action layer** — AI-assisted browser actions, extraction, observation, and self-healing workflows layered above deterministic control.
3. **Terminal browser compatibility** — text-first and terminal-native browsing for SSH, low-bandwidth, server, recovery, and agent-console use cases.

None of these surfaces should be treated as an afterthought.

## Playwright

Playwright is the deterministic automation substrate. BearBrowser should support Playwright-oriented control for:

- launching governed browser sessions
- connecting to browser contexts
- replaying deterministic flows
- capturing screenshots, PDFs, DOM snapshots, and traces
- validating compatibility against Firefox/Gecko, Chromium, WebKit, Chrome, and Edge-style expectations

BearBrowser should expose policy-mediated automation endpoints rather than allowing arbitrary remote debugging by default.

## Stagehand

Stagehand is the AI/browser action layer. BearBrowser should integrate with Stagehand for:

- natural-language actions
- structured extraction
- observation before action
- AI-assisted recovery when deterministic selectors fail
- cached/replayable actions when possible

Stagehand must not bypass PolicyFabric. Every action still maps to BearBrowser provenance events, policy decisions, and governed resource access.

## Terminal browser tier

BearBrowser must support terminal-first browsing strategies. This matters for SSH, server management, low-bandwidth environments, recovery shells, agent consoles, and SourceOS terminal surfaces.

Compatibility targets:

- **Carbonyl**: Chromium-class terminal browser for high-fidelity terminal rendering.
- **Browsh**: Firefox-backed modern text browser for remote/low-bandwidth sessions.
- **ELinks**: advanced text-mode browser with tables, frames, scripting/customization heritage.
- **Lynx**: classic minimal text browser baseline.
- **w3m/Links family**: practical fallback tier for simple terminal navigation.

Terminal browser support should not mean one binary. It means BearBrowser understands terminal browsing as a policy-governed capability class.

## SourceOS capability model

BearBrowser should advertise these capability classes to AgentPlane:

```yaml
capabilities:
  - browser.playwright
  - browser.stagehand
  - browser.terminal.carbonyl
  - browser.terminal.browsh
  - browser.terminal.elinks
  - browser.terminal.lynx
  - browser.capture.screenshot
  - browser.capture.domSnapshot
  - browser.capture.pdf
  - browser.provenance
```

## Policy rule

Automation frameworks do not grant authority. They only provide control mechanisms. Authority comes from PolicyFabric.

That means:

- Playwright cannot bypass policy.
- Stagehand cannot bypass policy.
- Terminal browser sessions cannot bypass policy.
- Remote debugging must be denied unless explicitly granted.
- Browser profiles, credentials, downloads, captures, and native messaging remain governed resources.

## Product posture

BearBrowser should feel easy for users and strict for systems:

- easy to install
- easy to update
- easy to diagnose
- easy to automate
- hard to misuse
- hard to leak credentials
- hard to escape mounts
- hard to confuse human and agent profiles

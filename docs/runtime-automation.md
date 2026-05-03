# BearBrowser Runtime Automation

BearBrowser automation is designed to be easy to install and hard to misuse.

## Install runtime tooling

The Homebrew Formula installs wrapper commands. Runtime JavaScript dependencies are installed separately:

```bash
bearbrowser-install-runtime-deps
```

This installs the dependencies declared in `package.json`, including Playwright and Stagehand compatibility packages.

## Playwright

Dry run:

```bash
bearbrowser-playwright --url https://example.com --dry-run
```

Guarded live smoke test:

```bash
export BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1
export BEARBROWSER_POLICY_DECISION_ID=policy-local-smoke
bearbrowser-playwright --url https://example.com
```

The live smoke test emits provenance-shaped events and requires a policy decision ID for `agent-runtime` mode.

## Stagehand

Dry run:

```bash
bearbrowser-stagehand --operation observe --url https://example.com --dry-run
```

Stagehand dependency validation is available, but live Stagehand execution remains blocked until provider credentials and the PolicyFabric adapter are implemented.

## Terminal browser fallback

Dry run:

```bash
bearbrowser-terminal --dry-run
```

Live terminal browsing:

```bash
bearbrowser-terminal --browser auto --url https://example.com
```

Backend preference order:

1. Carbonyl
2. Browsh
3. ELinks
4. w3m
5. Links
6. Lynx

## Governance rules

- Automation frameworks provide control mechanisms, not authority.
- PolicyFabric grants authority.
- BearBrowser emits provenance events.
- Remote debugging remains denied unless explicitly granted.
- Agent-runtime live browser operations require policy decision IDs.

## Current caveat

Playwright has a guarded live smoke path. Stagehand has dependency validation and dry-run scaffolding, but full live Stagehand execution is deferred until provider credentials, API compatibility, and PolicyFabric adapter integration are completed.

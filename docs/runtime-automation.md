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

## Automation receipts

Every automation transport start produces a `BrowserAutomationReceipt` before the transport is permitted to operate.

### Receipt structure

| Field | Description |
|---|---|
| `receiptId` | Stable URN: `urn:srcos:receipt:browser-automation:<local-id>` |
| `sessionRef` | Active BearBrowser session reference |
| `ownerRef` | Agent, plugin, or workspace that owns the session |
| `transport` | `native_pipe`, `cdp`, `webdriver`, `extension`, or `accessibility` |
| `permissionScope` | Explicit permissions: `read_dom`, `click`, `type`, `download`, `upload`, `inspect_network`, `inspect_cookies`, `use_credentials` |
| `origin` | `local`, `remote`, or `workspace` |
| `userVisible` | Always `true` |
| `revocable` | Always `true` |
| `policyDecisionRef` | PolicyFabric decision that admitted the session |
| `evidenceRefs` | Provenance artifact references |
| `capturedAt` | Session start timestamp |
| `status` | `active`, `revoked`, `ended`, `denied`, or `orphaned` |

Schema: `schemas/browser-automation-receipt.schema.json`
Example: `examples/browser-automation-receipt.example.json`

### Receipt lifecycle

1. **Transport starts** → receipt created with `status: active` and persisted to the provenance directory.
2. **Policy denied** → receipt created with `status: denied`; transport is not started.
3. **User revokes** → receipt updated to `status: revoked`, `revokedAt` set; transport terminated and session token invalidated.
4. **Session ends normally** → receipt updated to `status: ended`.
5. **Orphaned event** (no matching receipt) → event quarantined, never silently accepted.

### Verifying receipts

```bash
python3 scripts/bearbrowser-verify-automation-receipt.py examples/browser-automation-receipt.example.json
```

Run the built-in acceptance test suite:

```bash
python3 scripts/bearbrowser-verify-automation-receipt.py --self-test
```

## Visible session surface

The automation session UI (`automation/automation-session-ui.yaml`) shows:

1. Which agent/plugin/workspace owns the session
2. Active transport
3. Controlled tab/window/page scope
4. Granted permissions
5. Local/remote/workspace origin
6. Evidence receipt ID
7. One-click revoke/kill control

The surface is always visible when any automation transport is active and cannot be suppressed.

## Governance rules

- Automation frameworks provide control mechanisms, not authority.
- PolicyFabric grants authority.
- BearBrowser emits provenance events.
- Remote debugging remains denied unless explicitly granted.
- Agent-runtime live browser operations require policy decision IDs.
- No automation session may run without an owner.
- No automation session may run without a policy decision.
- Orphaned automation events are quarantined, never silently accepted.

See `policy/automation-receipt-policy.yaml` for the full runtime policy.

## Current caveat

Playwright has a guarded live smoke path. Stagehand has dependency validation and dry-run scaffolding, but full live Stagehand execution is deferred until provider credentials, API compatibility, and PolicyFabric adapter integration are completed.

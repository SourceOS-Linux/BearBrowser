# BearBrowser Provenance Events

BearBrowser emits provenance events so AgentPlane, PolicyFabric, and Prophet Workspace can reconstruct browser activity without relying on opaque agent logs.

## Workspace Operation Plane mapping

BearBrowser browser side effects must map to WorkspaceOperations:

- `browser.session.start` -> `BrowserSession`
- `browser.capture.create` -> `WebCapture`
- `browser.download.create` -> `DownloadArtifact`
- `browser.upload.create` -> `UploadArtifact`
- `browser.automation.run` -> `BrowserAutomationRun`
- `browser.diagnostics.export_redacted` -> `BrowserDiagnosticBundle`

Each operation emits `OperationEvent` lifecycle states: `start`, `progress`, `failure`, `retry`, `cancel`, and `complete`.
Operation records require actor attribution (`user`, `agent`, `system`, or `connector`) and TrustBoundary metadata (`externalSite`, `connector`, `authDomain`, `thirdPartyAutomation`).

## Event envelope

Each event should include:

- `eventType`
- `eventVersion`
- `timestamp`
- `sessionId`
- `agentId`
- `workspaceId`
- `profileMode`
- `policyDecisionId` when policy mediated
- `url` or `origin` when applicable
- `artifactPath` when an artifact is created
- `sha256` when an artifact is created
- `decision` for policy events
- `reason` for denied actions

Events must not contain passwords, payment card values, passkeys private material, biometric material, tokens, cookies, auth headers, prompt content, sensitive IDs, or other secret values.

## Required events

### `browser.session.started`

Emitted when a governed browser session starts.

Required fields:

- `sessionId`
- `agentId`
- `workspaceId`
- `profileMode`
- `profilePath`
- `policyBundleId`
- `mountPlanId`

### `browser.session.ended`

Emitted when a governed browser session exits.

Required fields:

- `sessionId`
- `exitCode`
- `durationMs`
- `cleanupStatus`

### `browser.navigation.requested`

Emitted before a navigation is attempted.

Required fields:

- `sessionId`
- `url`
- `origin`
- `policyDecisionId`
- `decision`

### `browser.navigation.completed`

Emitted after a navigation completes or fails.

Required fields:

- `sessionId`
- `url`
- `status`
- `httpStatus` when available
- `finalUrl`

### `browser.download.created`

Emitted when a file appears in the governed downloads mount.

Required fields:

- `sessionId`
- `url`
- `artifactPath`
- `sha256`
- `mimeType` when available
- `sizeBytes`

### `browser.capture.created`

Emitted when a screenshot, DOM snapshot, PDF, HAR file, or related capture artifact is created.

Required fields:

- `sessionId`
- `captureType`
- `artifactPath`
- `sha256`
- `url`
- `policyDecisionId`

### `browser.policy.violation`

Emitted when a browser action is denied or violates policy.

Required fields:

- `sessionId`
- `action`
- `resource`
- `decision`
- `reason`
- `policyDecisionId`

### `browser.credential.boundary`

Emitted when a credential boundary is evaluated, used, denied, or cleared.

Required fields:

- `sessionId`
- `credentialClass`
- `action`
- `decision`
- `policyDecisionId`
- `brokerBackend` such as `KeychainServices`, `SecretService`, `KWallet`, `PlatformPasskeys`, or `PolicyBrokerSessionCredential`

### `browser.credential.requested`

Emitted when a page, user action, or automation surface requests credential access.

Required fields:

- `sessionId`
- `credentialClass`
- `brokerBackend`
- `requestingOrigin`
- `policyDecisionId`

### `browser.credential.granted`

Emitted when the broker grants credential access.

Required fields:

- `sessionId`
- `credentialClass`
- `brokerBackend`
- `decision`
- `policyDecisionId`

### `browser.credential.denied`

Emitted when the broker denies credential access.

Required fields:

- `sessionId`
- `credentialClass`
- `brokerBackend`
- `reason`
- `policyDecisionId`

### `browser.credential.cleared`

Emitted when a session-scoped credential is cleared or expires.

Required fields:

- `sessionId`
- `credentialClass`
- `credentialScope`
- `cleanupStatus`

## Sinks

- AgentPlane receives runtime session and capability events.
- PolicyFabric receives decisions, violations, and policy-mediated action records.
- Prophet Workspace receives user-visible browser session, download, capture, and violation summaries.

## Retention posture

Raw browser artifacts are stored in governed mounts. Event records should store enough metadata to audit behavior without embedding full sensitive capture content in the event stream.

# BearBrowser AgentPlane and Prophet Workspace Integration

BearBrowser sessions are runtime capabilities registered through AgentPlane and surfaced to users through Prophet Workspace.

## Runtime path

```text
Matrix/Hermes command
  -> AgentPlane capability request
  -> PolicyFabric decision
  -> BearBrowser runtime wrapper
  -> provenance events
  -> Prophet Workspace state update
```

## Command routing rule

Matrix and Hermes may request or observe browser sessions, but they do not grant authority. PolicyFabric grants authority.

Commands must include or resolve:

- `sessionId`
- `agentId`
- `workspaceId`
- `profileMode`
- `automationSurface`
- `policyBundleId`
- `mountPlanId`

## Required boundaries

- Human profile state is never shared with agent-runtime sessions.
- Agent-runtime credentials are session-scoped and brokered.
- Downloads, captures, profile state, and provenance are governed mounts.
- Remote debugging is denied unless explicitly granted.
- Terminal browser backends are capability classes, not authority grants.
- Durable browser automation/capture/download/upload state is admitted through Workspace Operation Plane records only.

## Prophet Workspace state

Prophet Workspace should display:

- current session state,
- current or last URL,
- policy status,
- artifact count,
- latest provenance event,
- redacted artifact metadata,
- policy violation summaries.

By default, it must not display:

- cookie values,
- credential values,
- local storage values,
- unredacted capture contents without explicit user action.

## Adapter responsibilities

AgentPlane adapter:

- validates launch contract,
- records capability request,
- links policy decision IDs,
- accepts provenance events,
- updates session state.

PolicyFabric adapter:

- evaluates network, filesystem, credential, capture, native messaging, extension, clipboard, media, and remote-debugging requests,
- emits allow/deny decisions,
- records policy violations.

Prophet Workspace adapter:

- renders state transitions,
- indexes artifacts,
- shows redacted summaries,
- exposes user actions such as session end and provenance export.

## Events

BearBrowser uses the event contract in `docs/provenance-events.md`, lifecycle example in `agentplane/session-lifecycle.example.yaml`, and the Workspace Operation Plane contract in `agentplane/workspace-operation-plane.yaml`.

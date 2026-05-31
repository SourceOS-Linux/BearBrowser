# BearBrowser Reader Bridge

BearBrowser is the capture and provenance surface for the SocioProphet Feed Intelligence reader. It must not duplicate the `SocioProphet/socioprophet/socioprophet-web/client-vue` reader UI. Its job is to discover, capture, extract, and emit governed browser evidence that downstream SocioProphet surfaces can replay.

## Scope

BearBrowser owns:

- feed discovery from page metadata and explicit subscription links;
- page capture initiated by a human or governed agent session;
- canonical URL, source URL, title, timestamp, and content-hash extraction;
- provenance emission for browser-mediated evidence;
- policy-mediated handoff to the SocioProphet Feed Intelligence reader.

BearBrowser does not own:

- the full reader UI;
- SlashTopics governance scope definition;
- New Hope membrane admission decisions;
- MemoryMesh recall or writeback;
- MeshRush graph traversal;
- ActivityPub publication.

## Event vocabulary

The initial reader bridge emits these canonical browser event classes:

- `browser.feed.discovered`
- `browser.feed.subscribe_requested`
- `browser.page.captured`
- `browser.item.extracted`
- `browser.provenance.attached`
- `browser.reader.handoff_requested`
- `browser.reader.handoff_completed`
- `browser.reader.handoff_rejected`

Every event must include:

- event id;
- event type;
- created timestamp;
- browser profile class;
- session authority reference when an agent session is active;
- source URL;
- canonical URL when available;
- content hash or extraction hash;
- storage policy request;
- policy decision reference when available;
- downstream reader handoff reference when emitted.

## Capability model

BearBrowser advertises reader bridge capability classes to the SourceOS control plane and AgentPlane:

```yaml
capabilities:
  - browser.feed.discover
  - browser.feed.subscribeRequest
  - browser.page.capture
  - browser.item.extract
  - browser.reader.handoff
  - browser.provenance
```

These capabilities are control mechanisms, not authority grants. Authority still comes from PolicyFabric, AgentPlane session scope, and SourceOS service policy.

## Handoff contract

The handoff target is the canonical SocioProphet Vue reader shell:

```text
SocioProphet/socioprophet/socioprophet-web/client-vue
```

The handoff payload is intentionally small:

```yaml
ReaderHandoff:
  sourceUrl: string
  canonicalUrl: string?
  title: string?
  excerpt: string?
  contentHash: string
  capturedAt: string
  browserProfileClass: human | agent | terminal
  storagePolicyRequest: localOnly | localFirstSync | hostedPrivate | hostedPublic | externalAdapter
  evidenceRefs: string[]
```

The downstream reader is responsible for SlashTopics scope resolution, New Hope membrane evaluation, MemoryMesh posture, MeshRush graph views, and derived publication.

## Acceptance criteria

- Browser feed discovery can produce `browser.feed.discovered` without subscribing.
- Browser page capture can produce `browser.page.captured` without publishing.
- Reader handoff carries evidence references and storage policy request.
- Agent sessions cannot invoke reader handoff unless policy permits it.
- No browser bridge event implies ActivityPub publication or MemoryMesh writeback by itself.

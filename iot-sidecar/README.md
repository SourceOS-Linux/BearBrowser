# iot-sidecar

BearBrowser's smart-home / IoT control-plane sidecar. The BearBrowser cockpit
(`chrome://bearbrowser`) is the sovereign control plane for the user's smart-home
estate; this sidecar drives the devices — but **every** command it issues is
classified by the same policy engine that governs BearBrowser's browser actions,
before it can reach hardware.

## The two invariants (this is the moat)

### 1. One engine, not two

The sidecar reimplements **no** policy. Every device command is evaluated by the
canonical enforcement engine — `scripts/agent-control-bridge.py --surface iot` —
invoked as a subprocess by `src/gate.rs`:

```
python3 <repo>/scripts/agent-control-bridge.py \
    --surface iot --action <ACTION> \
    --param actor=<user|agent> --param userGesture=<true|false> \
    [--param k=v ...] [--approval-token <T>] --json
```

The gate parses the Decision JSON and permits device I/O **only** when
`decision == "permit"`. A deny, a non-zero exit, a spawn failure, or unparseable
output all **fail closed** — the device I/O never happens (`gate::evaluate` folds
every error path into a synthetic deny). Because there is exactly one place
physical actions are classified — and it is the same engine the Python
injection-containment proof exercises (`scripts/tests/test_iot_injection_containment.py`)
— that proof covers the Rust path too. An injected/agent `unlock-door` matches no
`policyCondition` and stays prohibited → denied, whether the request arrives over
the browser surface or this sidecar.

The action vocabulary (allowed / gated / prohibited) lives in
`policy/bearbrowser-contract.yaml` under `spec.iotActionContract`. The sidecar
never hardcodes it.

### 2. Loopback-only

`server::serve` binds `127.0.0.1` only and **refuses** any non-loopback address
(it checks both the requested and the actually-bound address). There is no
`0.0.0.0` path. Logs go to stderr. Nothing is emitted to the network except over
the loopback socket — no telemetry.

## Module tree

```
iot-sidecar/
├── Cargo.toml
├── README.md
└── src/
    ├── main.rs           # bootstrap: config, store, registry, loopback serve
    ├── gate.rs           # THE one-engine gate — subprocess → Decision, fail-closed
    ├── server.rs         # loopback REST + WS; every command POST hits the gate first
    ├── state.rs          # SQLite (rusqlite, bundled): devices + append-only event_log
    ├── credentials.rs    # seam to credential-broker; sidecar stores NO secrets
    ├── model.rs          # Device, DeviceId, DeviceState, Command, Capability, Actor, DeviceEvent
    └── adapters/
        ├── mod.rs        # DeviceAdapter trait + AdapterRegistry
        ├── mock.rs       # REAL hardware-free adapter (sample home) — end-to-end testable
        ├── homekit.rs    # HomeKit (HAP)            — device I/O TODO
        ├── matter.rs     # Matter fabric            — device I/O TODO
        ├── mdns_ssdp.rs  # mDNS/DNS-SD + SSDP        — discovery-only, I/O TODO
        ├── ha_bridge.rs  # Home Assistant REST/WS    — device I/O TODO
        └── mqtt.rs       # MQTT (Z2M/Tasmota/ESPHome)— device I/O TODO
```

## HTTP / WS API

| Method | Path                     | Notes                                              |
|--------|--------------------------|----------------------------------------------------|
| GET    | `/health`                | liveness                                           |
| GET    | `/devices`               | inventory (store ∪ live discovery)                 |
| GET    | `/devices/:id/state`     | live state read (an `allowed` action)              |
| POST   | `/devices/:id/command`   | **gate-governed**; body below                      |
| GET    | `/events`                | WebSocket event fan-out                            |

`POST /devices/:id/command` body:

```json
{
  "action": "toggle-power",
  "params": { "includesAction": "set-brightness" },
  "approval_token": "action:toggle-power",
  "actor": "user",
  "user_gesture": true
}
```

`actor` and `user_gesture` are **required and load-bearing**: they are what let
the gate reclassify a prohibited physical action (e.g. `unlock-door`) down to
gated on an explicit cockpit gesture (`actor == "user"` **and**
`user_gesture == true`). The cockpit sets them from trusted UI state; an agent
cannot forge `actor: "user"`. The response echoes the raw gate decision and
whether device I/O actually ran (`applied`).

## Running

From the **BearBrowser repo root** (so the sidecar can find the bridge):

```bash
cargo run --manifest-path iot-sidecar/Cargo.toml -- --repo-root "$PWD"
# ephemeral loopback port, sample "mock" home, SQLite at runtime/iot-sidecar.db
```

Useful flags / env:

- `--port N` (default `0` = ephemeral) — always `127.0.0.1`
- `--repo-root DIR` (default CWD) — locates `agent-control-bridge.py`
- `--db PATH` / `--memory` — store location, or ephemeral in-memory
- env: `IOT_SIDECAR_PORT`, `BEARBROWSER_REPO_ROOT`, `IOT_SIDECAR_DB`, `RUST_LOG`

The sidecar **refuses to start** if `scripts/agent-control-bridge.py` is not found
under `--repo-root` — it will not run ungoverned.

Smoke test with the mock adapter:

```bash
# list devices (triggers discovery of the sample home)
curl -s http://127.0.0.1:<port>/devices | jq

# gated action WITHOUT a token → gate denies, applied=false
curl -s -X POST http://127.0.0.1:<port>/devices/mock-living-lamp/command \
  -H 'content-type: application/json' \
  -d '{"action":"toggle-power","actor":"agent"}'

# gated action WITH a token → permit, applied=true
curl -s -X POST http://127.0.0.1:<port>/devices/mock-living-lamp/command \
  -H 'content-type: application/json' \
  -d '{"action":"toggle-power","actor":"user","user_gesture":true,"approval_token":"action:toggle-power"}'

# injected/agent unlock → prohibited, denied, applied=false
curl -s -X POST http://127.0.0.1:<port>/devices/mock-front-lock/command \
  -H 'content-type: application/json' \
  -d '{"action":"unlock-door","actor":"agent"}'
```

## Adding a protocol adapter

1. Add `src/adapters/<proto>.rs` with a struct implementing `DeviceAdapter`
   (see `src/adapters/mod.rs`). `protocol()` returns the stable tag; `discover`,
   `read_state`, `apply`, and `subscribe` are the device I/O.
2. **Put no policy in the adapter.** `apply` is only ever reached *after*
   `gate::evaluate` returned `permit`. Adapters are pure device I/O.
3. **Never store secrets.** Resolve credentials per-call via
   `crate::credentials` (the `credential-broker` seam). Hold a `SecretHandle`,
   not a secret.
4. Register it in `AdapterRegistry::with_defaults` and add `pub mod <proto>;` to
   `src/adapters/mod.rs`.

`mock.rs` is the reference: a complete, hardware-free implementation that makes
the whole sidecar testable end-to-end without any device.

## Credentials

The sidecar stores **no** device credentials. `src/credentials.rs` defines the
`BrokerTransport` seam that delegates to the repo's `credential-broker/`
(Keychain / Secret Service / etc — see `credential-broker/{macos,linux}-backends.yaml`).
The broker daemon's IPC transport is a documented TODO; until it is wired,
`resolve` fails closed rather than fabricating or caching a secret.

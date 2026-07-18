//! Core domain model shared across adapters, the gate, the state store, and the
//! server. These types are the wire contract the BearBrowser cockpit Vue app
//! consumes, so they all derive `Serialize`/`Deserialize`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

/// Stable, opaque identifier for a device. Newtype so it can never be confused
/// with an arbitrary string (e.g. a room name or an action).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeviceId(pub String);

impl DeviceId {
    pub fn new(s: impl Into<String>) -> Self {
        DeviceId(s.into())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for DeviceId {
    fn from(s: &str) -> Self {
        DeviceId(s.to_string())
    }
}

/// What a device can do. Capabilities map to the action vocabulary in
/// `policy/bearbrowser-contract.yaml` (`spec.iotActionContract`) — the cockpit
/// only renders controls a device advertises, and every control still passes
/// through the gate before touching hardware.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Capability {
    OnOff,
    Brightness,
    Color,
    Thermostat,
    Fan,
    Cover,
    Lock,
    MediaPlayback,
    Volume,
    Sensor,
    Camera,
    Security,
    Scene,
}

/// A discovered device. `last_state` is a cached snapshot; the authoritative
/// live read is `DeviceAdapter::read_state`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Device {
    pub id: DeviceId,
    /// Protocol tag, matches `DeviceAdapter::protocol()` (e.g. "matter", "mock").
    pub protocol: String,
    pub name: String,
    /// Optional room / area assignment for cockpit grouping.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    pub capabilities: Vec<Capability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_state: Option<DeviceState>,
}

/// A point-in-time reading of a device. `attributes` is an open map so adapters
/// can surface protocol-specific fields (e.g. `{"brightness": 40}`) without a
/// schema change; the cockpit renders known keys and ignores the rest.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DeviceState {
    pub online: bool,
    #[serde(default)]
    pub attributes: serde_json::Map<String, serde_json::Value>,
}

impl DeviceState {
    pub fn online() -> Self {
        DeviceState {
            online: true,
            attributes: serde_json::Map::new(),
        }
    }
    pub fn with(mut self, key: &str, value: serde_json::Value) -> Self {
        self.attributes.insert(key.to_string(), value);
        self
    }
}

/// Who originated a command. Only `User` (an explicit cockpit gesture) can ever
/// reclassify a prohibited physical action down to gated — see the policy
/// `policyConditions` in the contract. An agent can never forge this: it is set
/// by the trusted cockpit UI, not by request body content the planner controls.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Actor {
    User,
    Agent,
}

impl Actor {
    pub fn as_str(&self) -> &'static str {
        match self {
            Actor::User => "user",
            Actor::Agent => "agent",
        }
    }
}

/// A requested device command. This is exactly what the gate serializes into
/// the canonical bridge invocation; the sidecar adds no policy of its own.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Command {
    /// Action name from the IoT action vocabulary (e.g. "toggle-power",
    /// "set-brightness", "unlock-door").
    pub action: String,
    /// Planner/cockpit-supplied params that may reclassify the action
    /// (e.g. `includesAction=unlock-door` on a scene). Passed verbatim to the
    /// bridge as `--param k=v`.
    #[serde(default)]
    pub params: BTreeMap<String, String>,
    /// Per-action approval token for gated actions (e.g. "action:toggle-power").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_token: Option<String>,
    /// Command origin. Forwarded to the bridge as `--param actor=...`.
    pub actor: Actor,
    /// Explicit present-tense user gesture flag from the cockpit. Forwarded as
    /// `--param userGesture=true|false`. Required for the gate's prohibited→gated
    /// reclassification to fire.
    #[serde(default)]
    pub user_gesture: bool,
}

/// An event emitted by an adapter (state change, discovery, availability). These
/// fan out to the cockpit over the loopback WebSocket and are appended to the
/// state store's append-only `event_log`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceEvent {
    pub event_id: String,
    pub device_id: DeviceId,
    pub protocol: String,
    /// e.g. "state-changed", "discovered", "unavailable".
    pub kind: String,
    #[serde(default)]
    pub state: Option<DeviceState>,
    /// Unix epoch milliseconds.
    pub at_ms: i64,
}

impl DeviceEvent {
    pub fn now(device_id: DeviceId, protocol: impl Into<String>, kind: impl Into<String>) -> Self {
        DeviceEvent {
            event_id: uuid::Uuid::new_v4().to_string(),
            device_id,
            protocol: protocol.into(),
            kind: kind.into(),
            state: None,
            at_ms: crate::now_ms(),
        }
    }
}

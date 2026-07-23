//! Wire + domain types shared across the capture sidecar.

use serde::{Deserialize, Serialize};

/// Who initiated an action. Mirrors the bridge's `actor` param — only `user`
/// with a real gesture can reclassify a gated action down to permitted.
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

impl Default for Actor {
    fn default() -> Self {
        Actor::Agent
    }
}

/// A request to perform a governed action, forwarded verbatim to the gate.
/// `action` is the natural action name (e.g. "capture-start", "firewall-set").
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Command {
    pub action: String,
    #[serde(default)]
    pub actor: Actor,
    #[serde(rename = "userGesture", default)]
    pub user_gesture: bool,
    #[serde(default)]
    pub params: Vec<(String, String)>,
    #[serde(rename = "approvalToken", default)]
    pub approval_token: Option<String>,
}

/// Which capture engine the host has, in preference order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    /// Wireshark's headless capture tool — writes true pcapng.
    Dumpcap,
    /// Wireshark CLI — parsed fields, human-readable.
    Tshark,
    /// BSD/Linux tcpdump.
    Tcpdump,
}

impl Engine {
    pub fn label(&self) -> &'static str {
        match self {
            Engine::Dumpcap => "dumpcap",
            Engine::Tshark => "tshark",
            Engine::Tcpdump => "tcpdump",
        }
    }
    /// dumpcap emits a real pcapng file; the others emit text we buffer as-is.
    pub fn writes_pcap(&self) -> bool {
        matches!(self, Engine::Dumpcap)
    }
}

/// Category of a remote endpoint, ported from the native shell's classifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConnCategory {
    Tracker,
    Analytics,
    Cdn,
    Unknown,
}

/// A firewall decision for a domain. Persisted across sessions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FirewallDecision {
    /// Default: follow the blocklist, prompt on unknowns.
    Ask,
    Allow,
    Block,
}

impl Default for FirewallDecision {
    fn default() -> Self {
        FirewallDecision::Ask
    }
}

/// One observed connection, streamed to the cockpit map panel.
#[derive(Clone, Debug, Serialize)]
pub struct ConnectionRecord {
    /// eTLD+1 of the endpoint (e.g. "doubleclick.net").
    pub domain: String,
    #[serde(rename = "pageUrl")]
    pub page_url: String,
    #[serde(rename = "resourceType")]
    pub resource_type: String,
    pub category: ConnCategory,
    pub blocked: bool,
    /// Unix seconds.
    pub timestamp: u64,
}

/// Events fanned out over the `/events` WebSocket. One text-JSON frame each,
/// matching the iot-sidecar convention.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum SidecarEvent {
    /// A raw line from the capture engine.
    Packet { line: String },
    /// A newly observed connection (from the browser's own network telemetry).
    Connection(ConnectionRecord),
    /// Capture lifecycle transitions, so the panel can update its controls.
    CaptureState {
        running: bool,
        engine: Option<String>,
    },
}

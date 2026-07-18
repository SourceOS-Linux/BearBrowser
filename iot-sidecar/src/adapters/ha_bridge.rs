//! Home Assistant bridge adapter — talks to a local Home Assistant instance's
//! REST API (`/api/states`, `/api/services/...`). The long-lived access token is
//! NEVER stored here; it is resolved per-call through the credential broker seam
//! (`crate::credentials`).
//!
//! Device I/O is left as documented TODOs; the trait shape, credential seam, and
//! registration are real and compile.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::credentials::SecretHandle;
use crate::model::{Command, Device, DeviceId, DeviceState};
use anyhow::Result;

pub struct HomeAssistantAdapter {
    /// Loopback/base URL of the local HA instance (e.g. http://127.0.0.1:8123).
    base_url: String,
    /// Handle to the long-lived token; resolved on demand via the broker.
    token: SecretHandle,
}

impl HomeAssistantAdapter {
    pub fn new() -> Self {
        HomeAssistantAdapter {
            base_url: "http://127.0.0.1:8123".to_string(),
            token: SecretHandle::new("ha.longLivedToken", "home-assistant-rest"),
        }
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        HomeAssistantAdapter {
            base_url: base_url.into(),
            token: SecretHandle::new("ha.longLivedToken", "home-assistant-rest"),
        }
    }
}

impl Default for HomeAssistantAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for HomeAssistantAdapter {
    fn protocol(&self) -> &'static str {
        "ha"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        // TODO(ha): GET {base_url}/api/states with a broker-resolved bearer token,
        // map HA entities → Device (domain → Capability set).
        let _ = (&self.base_url, &self.token);
        todo!("Home Assistant discover: GET /api/states")
    }

    async fn read_state(&self, _id: &DeviceId) -> Result<DeviceState> {
        // TODO(ha): GET {base_url}/api/states/{entity_id}.
        todo!("Home Assistant read_state: GET /api/states/{{entity}}")
    }

    async fn apply(&self, _id: &DeviceId, _command: &Command) -> Result<()> {
        // TODO(ha): POST {base_url}/api/services/{domain}/{service}. Reached ONLY
        // after gate::evaluate returned permit — no policy here.
        todo!("Home Assistant apply: POST /api/services/{{domain}}/{{service}}")
    }

    async fn subscribe(&self, _filter: SubscriptionFilter) -> Result<EventStream> {
        // TODO(ha): open the HA WebSocket API and subscribe_events → DeviceEvent.
        todo!("Home Assistant subscribe: WS /api/websocket subscribe_events")
    }
}

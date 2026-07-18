//! Mock adapter — a real, hardware-free implementation so the whole sidecar
//! (server + gate + store + WS) is testable end-to-end without any device.
//!
//! It keeps an in-memory device table and mutates cached attributes on `apply`,
//! emitting a `state-changed` event on its broadcast channel. It performs no
//! network I/O.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::model::{Capability, Command, Device, DeviceEvent, DeviceId, DeviceState};
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

pub struct MockAdapter {
    devices: Mutex<HashMap<DeviceId, Device>>,
    events: broadcast::Sender<DeviceEvent>,
}

impl MockAdapter {
    pub fn new() -> Self {
        let (events, _rx) = broadcast::channel(256);
        MockAdapter {
            devices: Mutex::new(HashMap::new()),
            events,
        }
    }

    /// A small sample home so the cockpit has something to render immediately.
    pub fn with_sample_home() -> Self {
        let this = Self::new();
        let seed = vec![
            Self::device("mock-living-lamp", "Living Room Lamp", Some("Living Room"), vec![Capability::OnOff, Capability::Brightness, Capability::Color]),
            Self::device("mock-hallway-thermostat", "Hallway Thermostat", Some("Hallway"), vec![Capability::Thermostat, Capability::Sensor]),
            Self::device("mock-front-lock", "Front Door Lock", Some("Entry"), vec![Capability::Lock]),
            Self::device("mock-garage", "Garage Door", Some("Garage"), vec![Capability::Cover]),
            Self::device("mock-den-speaker", "Den Speaker", Some("Den"), vec![Capability::MediaPlayback, Capability::Volume]),
        ];
        let mut guard = this.devices.lock().unwrap();
        for d in seed {
            guard.insert(d.id.clone(), d);
        }
        drop(guard);
        this
    }

    fn device(id: &str, name: &str, room: Option<&str>, caps: Vec<Capability>) -> Device {
        let mut state = DeviceState::online();
        state.attributes.insert("power".into(), serde_json::json!("off"));
        Device {
            id: DeviceId::new(id),
            protocol: "mock".to_string(),
            name: name.to_string(),
            room: room.map(|r| r.to_string()),
            capabilities: caps,
            last_state: Some(state),
        }
    }
}

impl Default for MockAdapter {
    fn default() -> Self {
        Self::with_sample_home()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for MockAdapter {
    fn protocol(&self) -> &'static str {
        "mock"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        let guard = self.devices.lock().unwrap();
        Ok(guard.values().cloned().collect())
    }

    async fn read_state(&self, id: &DeviceId) -> Result<DeviceState> {
        let guard = self.devices.lock().unwrap();
        guard
            .get(id)
            .and_then(|d| d.last_state.clone())
            .ok_or_else(|| anyhow!("mock: unknown device {id}"))
    }

    async fn apply(&self, id: &DeviceId, command: &Command) -> Result<()> {
        let mut guard = self.devices.lock().unwrap();
        let device = guard
            .get_mut(id)
            .ok_or_else(|| anyhow!("mock: unknown device {id}"))?;
        let state = device
            .last_state
            .get_or_insert_with(DeviceState::online);

        // Reflect the command in cached attributes so read-back is coherent.
        match command.action.as_str() {
            "toggle-power" => {
                let now = state
                    .attributes
                    .get("power")
                    .and_then(|v| v.as_str())
                    .unwrap_or("off");
                let next = if now == "on" { "off" } else { "on" };
                state.attributes.insert("power".into(), serde_json::json!(next));
            }
            "lock-door" => {
                state.attributes.insert("lock".into(), serde_json::json!("locked"));
            }
            "unlock-door" => {
                state.attributes.insert("lock".into(), serde_json::json!("unlocked"));
            }
            other => {
                // Generic: record each param as an attribute.
                state.attributes.insert("last_action".into(), serde_json::json!(other));
                for (k, v) in &command.params {
                    state.attributes.insert(k.clone(), serde_json::json!(v));
                }
            }
        }

        let mut event = DeviceEvent::now(id.clone(), "mock", "state-changed");
        event.state = Some(state.clone());
        // Ignore send errors (no subscribers is fine).
        let _ = self.events.send(event);
        Ok(())
    }

    async fn subscribe(&self, filter: SubscriptionFilter) -> Result<EventStream> {
        let rx = self.events.subscribe();
        let stream = BroadcastStream::new(rx).filter_map(move |res| {
            let ev = res.ok()?;
            if !filter.devices.is_empty() && !filter.devices.contains(&ev.device_id) {
                return None;
            }
            if !filter.kinds.is_empty() && !filter.kinds.contains(&ev.kind) {
                return None;
            }
            Some(ev)
        });
        Ok(Box::pin(stream))
    }
}

//! MQTT adapter — controls devices over a local MQTT broker (Zigbee2MQTT,
//! Tasmota, ESPHome, Home Assistant MQTT discovery). Broker credentials are
//! resolved through the credential broker seam, never stored in the sidecar.
//!
//! Device I/O is left as documented TODOs; the trait shape, credential seam, and
//! registration are real and compile.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::credentials::SecretHandle;
use crate::model::{Command, Device, DeviceId, DeviceState};
use anyhow::Result;

pub struct MqttAdapter {
    /// Broker host:port (loopback by default; a LAN broker is configured explicitly).
    broker: String,
    /// Handle to the broker username/password, resolved on demand.
    credential: SecretHandle,
    /// Discovery topic prefix (Home Assistant MQTT discovery convention).
    discovery_prefix: String,
}

impl MqttAdapter {
    pub fn new() -> Self {
        MqttAdapter {
            broker: "127.0.0.1:1883".to_string(),
            credential: SecretHandle::new("mqtt.broker", "mqtt-broker-auth"),
            discovery_prefix: "homeassistant".to_string(),
        }
    }

    pub fn with_broker(broker: impl Into<String>) -> Self {
        MqttAdapter {
            broker: broker.into(),
            credential: SecretHandle::new("mqtt.broker", "mqtt-broker-auth"),
            discovery_prefix: "homeassistant".to_string(),
        }
    }
}

impl Default for MqttAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for MqttAdapter {
    fn protocol(&self) -> &'static str {
        "mqtt"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        // TODO(mqtt): connect to `broker` (broker-resolved creds), subscribe to
        // `{discovery_prefix}/+/+/config`, parse discovery payloads → Device.
        let _ = (&self.broker, &self.credential, &self.discovery_prefix);
        todo!("MQTT discover: subscribe discovery_prefix/+/+/config")
    }

    async fn read_state(&self, _id: &DeviceId) -> Result<DeviceState> {
        // TODO(mqtt): read retained state topic for the device.
        todo!("MQTT read_state: retained state topic read")
    }

    async fn apply(&self, _id: &DeviceId, _command: &Command) -> Result<()> {
        // TODO(mqtt): publish to the device's command topic. Post-gate-permit only.
        todo!("MQTT apply: publish to command topic")
    }

    async fn subscribe(&self, _filter: SubscriptionFilter) -> Result<EventStream> {
        // TODO(mqtt): subscribe to state topics, map messages → DeviceEvent.
        todo!("MQTT subscribe: state topic messages → DeviceEvent")
    }
}

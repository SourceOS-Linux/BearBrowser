//! Adapter spine — the extensibility surface of the sidecar.
//!
//! Each protocol (HomeKit, Matter, mDNS/SSDP discovery, Home Assistant, MQTT,
//! and the hardware-free `mock`) implements [`DeviceAdapter`]. The server never
//! talks to a protocol directly; it looks an adapter up in the [`AdapterRegistry`]
//! by protocol tag and calls the trait. Adding a protocol = add a module that
//! implements the trait and register it in `AdapterRegistry::with_defaults`.
//!
//! IMPORTANT: an adapter's `apply` is only ever reached AFTER `gate::evaluate`
//! returned `permit`. Adapters therefore contain NO policy — they are pure device
//! I/O. This keeps the one-engine invariant intact.

pub mod ha_bridge;
pub mod homekit;
pub mod matter;
pub mod mdns_ssdp;
pub mod mock;
pub mod mqtt;

use crate::model::{Command, Device, DeviceEvent, DeviceId, DeviceState};
use anyhow::Result;
use futures::stream::Stream;
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;

/// A stream of device events an adapter surfaces via `subscribe`.
pub type EventStream = Pin<Box<dyn Stream<Item = DeviceEvent> + Send>>;

/// Filter passed to `subscribe`. An empty filter means "all devices, all kinds".
#[derive(Clone, Debug, Default)]
pub struct SubscriptionFilter {
    /// Restrict to these device ids (empty = all).
    pub devices: Vec<DeviceId>,
    /// Restrict to these event kinds (empty = all).
    pub kinds: Vec<String>,
}

impl SubscriptionFilter {
    pub fn all() -> Self {
        SubscriptionFilter::default()
    }
}

/// The extensibility spine. Every protocol implements this and only this.
#[async_trait::async_trait]
pub trait DeviceAdapter: Send + Sync {
    /// Stable protocol tag; matches `Device::protocol` and the registry key.
    fn protocol(&self) -> &'static str;

    /// Enumerate devices this adapter can currently see.
    async fn discover(&self) -> Result<Vec<Device>>;

    /// Read the live state of one device.
    async fn read_state(&self, id: &DeviceId) -> Result<DeviceState>;

    /// Apply a (already gate-permitted) command to a device. This is the ONLY
    /// method that causes a physical effect; implementations perform no policy.
    async fn apply(&self, id: &DeviceId, command: &Command) -> Result<()>;

    /// Subscribe to this adapter's event stream (state changes, availability).
    async fn subscribe(&self, filter: SubscriptionFilter) -> Result<EventStream>;
}

/// Registry of adapters keyed by protocol tag.
#[derive(Clone)]
pub struct AdapterRegistry {
    adapters: HashMap<&'static str, Arc<dyn DeviceAdapter>>,
}

impl AdapterRegistry {
    pub fn new() -> Self {
        AdapterRegistry {
            adapters: HashMap::new(),
        }
    }

    /// Register an adapter under its `protocol()` tag.
    pub fn register(&mut self, adapter: Arc<dyn DeviceAdapter>) {
        self.adapters.insert(adapter.protocol(), adapter);
    }

    pub fn get(&self, protocol: &str) -> Option<Arc<dyn DeviceAdapter>> {
        self.adapters.get(protocol).cloned()
    }

    pub fn protocols(&self) -> Vec<&'static str> {
        self.adapters.keys().copied().collect()
    }

    pub fn all(&self) -> Vec<Arc<dyn DeviceAdapter>> {
        self.adapters.values().cloned().collect()
    }

    /// Build the default registry. Every protocol adapter is registered; only
    /// `mock` performs real (hardware-free) I/O today — the rest carry the real
    /// trait shape and registration with device I/O left as documented TODOs.
    pub fn with_defaults() -> Self {
        let mut reg = AdapterRegistry::new();
        reg.register(Arc::new(mock::MockAdapter::with_sample_home()));
        reg.register(Arc::new(homekit::HomeKitAdapter::new()));
        reg.register(Arc::new(matter::MatterAdapter::new()));
        reg.register(Arc::new(mdns_ssdp::MdnsSsdpAdapter::new()));
        reg.register(Arc::new(ha_bridge::HomeAssistantAdapter::new()));
        reg.register(Arc::new(mqtt::MqttAdapter::new()));
        reg
    }
}

impl Default for AdapterRegistry {
    fn default() -> Self {
        Self::with_defaults()
    }
}

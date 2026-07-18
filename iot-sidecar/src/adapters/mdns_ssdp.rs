//! Discovery-only adapter — mDNS/DNS-SD + SSDP (UPnP). It finds devices on the
//! LAN and surfaces them as `Device`s for the cockpit to adopt; it does not
//! control them (`apply` is not supported — control belongs to a protocol
//! adapter once the device is adopted).
//!
//! Discovery I/O is left as documented TODOs; the trait shape and registration
//! are real and compile.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::model::{Command, Device, DeviceId, DeviceState};
use anyhow::{bail, Result};

pub struct MdnsSsdpAdapter {
    /// Service types to browse (e.g. `_hap._tcp`, `_matter._tcp`, `_googlecast._tcp`).
    service_types: Vec<&'static str>,
}

impl MdnsSsdpAdapter {
    pub fn new() -> Self {
        MdnsSsdpAdapter {
            service_types: vec![
                "_hap._tcp",
                "_matter._tcp",
                "_matterc._udp",
                "_googlecast._tcp",
                "_airplay._tcp",
            ],
        }
    }
}

impl Default for MdnsSsdpAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for MdnsSsdpAdapter {
    fn protocol(&self) -> &'static str {
        "mdns-ssdp"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        // TODO(discovery): browse mDNS service types + SSDP M-SEARCH, dedupe,
        // and map advertisements → Device (with the protocol hint from the
        // service type so the cockpit can route adoption to the right adapter).
        let _ = &self.service_types;
        todo!("mDNS/SSDP discover: multicast browse + SSDP M-SEARCH")
    }

    async fn read_state(&self, _id: &DeviceId) -> Result<DeviceState> {
        bail!("mdns-ssdp is discovery-only: no state reads (adopt via a protocol adapter)")
    }

    async fn apply(&self, _id: &DeviceId, _command: &Command) -> Result<()> {
        bail!("mdns-ssdp is discovery-only: no control (adopt via a protocol adapter)")
    }

    async fn subscribe(&self, _filter: SubscriptionFilter) -> Result<EventStream> {
        // TODO(discovery): stream add/remove advertisements as `discovered` /
        // `unavailable` DeviceEvents.
        todo!("mDNS/SSDP subscribe: advertisement add/remove stream")
    }
}

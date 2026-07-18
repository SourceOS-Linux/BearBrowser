//! HomeKit Accessory Protocol (HAP) adapter — controls accessories over the
//! local HAP transport. Pairing keys are secrets and are resolved through the
//! credential broker seam, never stored in the sidecar.
//!
//! Device I/O is left as documented TODOs; the trait shape and registration are
//! real and compile.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::credentials::SecretHandle;
use crate::model::{Command, Device, DeviceId, DeviceState};
use anyhow::Result;

pub struct HomeKitAdapter {
    /// Handle to the controller's long-term pairing key material.
    pairing_key: SecretHandle,
}

impl HomeKitAdapter {
    pub fn new() -> Self {
        HomeKitAdapter {
            pairing_key: SecretHandle::new("homekit.pairingKey", "hap-controller"),
        }
    }
}

impl Default for HomeKitAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for HomeKitAdapter {
    fn protocol(&self) -> &'static str {
        "homekit"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        // TODO(homekit): browse _hap._tcp accessories and read their accessory
        // database (services/characteristics) → Device + Capability set.
        let _ = &self.pairing_key;
        todo!("HomeKit discover: _hap._tcp accessory database enumeration")
    }

    async fn read_state(&self, _id: &DeviceId) -> Result<DeviceState> {
        // TODO(homekit): GET characteristics for the accessory's aid/iid set.
        todo!("HomeKit read_state: characteristic read")
    }

    async fn apply(&self, _id: &DeviceId, _command: &Command) -> Result<()> {
        // TODO(homekit): PUT characteristics. Reached only post-gate-permit.
        todo!("HomeKit apply: characteristic write")
    }

    async fn subscribe(&self, _filter: SubscriptionFilter) -> Result<EventStream> {
        // TODO(homekit): register for characteristic change notifications (EVENT).
        todo!("HomeKit subscribe: characteristic event notifications")
    }
}

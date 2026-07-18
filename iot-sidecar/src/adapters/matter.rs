//! Matter adapter — controls Matter nodes on the local fabric (operational
//! credentials via the credential broker seam). Commissioning (`pair-device`) is
//! a PROHIBITED IoT action in the contract and is blocked at the gate before it
//! ever reaches this adapter.
//!
//! Device I/O is left as documented TODOs; the trait shape and registration are
//! real and compile.

use super::{DeviceAdapter, EventStream, SubscriptionFilter};
use crate::credentials::SecretHandle;
use crate::model::{Command, Device, DeviceId, DeviceState};
use anyhow::Result;

pub struct MatterAdapter {
    /// Handle to the fabric's operational credentials (NOC/IPK).
    fabric_credential: SecretHandle,
}

impl MatterAdapter {
    pub fn new() -> Self {
        MatterAdapter {
            fabric_credential: SecretHandle::new("matter.operationalCred", "matter-fabric"),
        }
    }
}

impl Default for MatterAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl DeviceAdapter for MatterAdapter {
    fn protocol(&self) -> &'static str {
        "matter"
    }

    async fn discover(&self) -> Result<Vec<Device>> {
        // TODO(matter): enumerate commissioned nodes on the fabric and read their
        // descriptor cluster / endpoints → Device + Capability set.
        let _ = &self.fabric_credential;
        todo!("Matter discover: fabric node enumeration via descriptor cluster")
    }

    async fn read_state(&self, _id: &DeviceId) -> Result<DeviceState> {
        // TODO(matter): read cluster attributes (OnOff, LevelControl, etc.).
        todo!("Matter read_state: cluster attribute read")
    }

    async fn apply(&self, _id: &DeviceId, _command: &Command) -> Result<()> {
        // TODO(matter): invoke cluster command. Reached only post-gate-permit.
        todo!("Matter apply: cluster command invoke")
    }

    async fn subscribe(&self, _filter: SubscriptionFilter) -> Result<EventStream> {
        // TODO(matter): subscribe to attribute reports → DeviceEvent.
        todo!("Matter subscribe: attribute report subscription")
    }
}

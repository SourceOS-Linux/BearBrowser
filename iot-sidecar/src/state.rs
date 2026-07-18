//! State store — SQLite via `rusqlite` (bundled, so it compiles without a
//! system libsqlite3). Two tables:
//!   * `devices`     — the known device inventory + cached last state;
//!   * `event_log`   — append-only device/gate event history.
//!
//! The connection is guarded by a `Mutex`; all methods are synchronous and
//! short-lived (no `.await` is held across the lock), so the store is cheap to
//! call from async handlers.

use crate::model::{Capability, Device, DeviceEvent, DeviceId, DeviceState};
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::{Arc, Mutex};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS devices (
    id           TEXT PRIMARY KEY,
    protocol     TEXT NOT NULL,
    name         TEXT NOT NULL,
    room         TEXT,
    capabilities TEXT NOT NULL,   -- JSON array of Capability
    last_state   TEXT,            -- JSON DeviceState (nullable)
    updated_at   INTEGER NOT NULL -- unix epoch millis
);

CREATE TABLE IF NOT EXISTS event_log (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id   TEXT NOT NULL,
    device_id  TEXT NOT NULL,
    protocol   TEXT NOT NULL,
    kind       TEXT NOT NULL,
    payload    TEXT NOT NULL,     -- JSON DeviceEvent
    at_ms      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_log_device ON event_log(device_id);
CREATE INDEX IF NOT EXISTS idx_event_log_at ON event_log(at_ms);
"#;

/// Thread-safe handle to the SQLite-backed store.
#[derive(Clone)]
pub struct Store {
    conn: Arc<Mutex<Connection>>,
}

impl Store {
    /// Open (or create) the store at `path` and run migrations. Pass
    /// `":memory:"` for an ephemeral store (used by tests / `--memory`).
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path.as_ref())
            .with_context(|| format!("opening sqlite at {}", path.as_ref().display()))?;
        Self::from_conn(conn)
    }

    /// Open a purely in-memory store.
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().context("opening in-memory sqlite")?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self> {
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
            .ok();
        conn.execute_batch(SCHEMA).context("running migrations")?;
        Ok(Store {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Insert or update a device (idempotent on `id`).
    pub fn upsert_device(&self, device: &Device) -> Result<()> {
        let caps = serde_json::to_string(&device.capabilities)?;
        let last_state = match &device.last_state {
            Some(s) => Some(serde_json::to_string(s)?),
            None => None,
        };
        let conn = self.conn.lock().expect("store mutex poisoned");
        conn.execute(
            "INSERT INTO devices (id, protocol, name, room, capabilities, last_state, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(id) DO UPDATE SET
                protocol=excluded.protocol,
                name=excluded.name,
                room=excluded.room,
                capabilities=excluded.capabilities,
                last_state=COALESCE(excluded.last_state, devices.last_state),
                updated_at=excluded.updated_at",
            params![
                device.id.as_str(),
                device.protocol,
                device.name,
                device.room,
                caps,
                last_state,
                crate::now_ms(),
            ],
        )?;
        Ok(())
    }

    /// List all known devices.
    pub fn list_devices(&self) -> Result<Vec<Device>> {
        let conn = self.conn.lock().expect("store mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, protocol, name, room, capabilities, last_state FROM devices ORDER BY name",
        )?;
        let rows = stmt.query_map([], Self::row_to_device)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Fetch one device by id.
    pub fn get_device(&self, id: &DeviceId) -> Result<Option<Device>> {
        let conn = self.conn.lock().expect("store mutex poisoned");
        let device = conn
            .query_row(
                "SELECT id, protocol, name, room, capabilities, last_state FROM devices WHERE id = ?1",
                params![id.as_str()],
                Self::row_to_device,
            )
            .optional()?;
        Ok(device)
    }

    /// Update the cached `last_state` for a device.
    pub fn update_state(&self, id: &DeviceId, state: &DeviceState) -> Result<()> {
        let json = serde_json::to_string(state)?;
        let conn = self.conn.lock().expect("store mutex poisoned");
        conn.execute(
            "UPDATE devices SET last_state = ?2, updated_at = ?3 WHERE id = ?1",
            params![id.as_str(), json, crate::now_ms()],
        )?;
        Ok(())
    }

    /// Append an event to the append-only log.
    pub fn append_event(&self, event: &DeviceEvent) -> Result<()> {
        let payload = serde_json::to_string(event)?;
        let conn = self.conn.lock().expect("store mutex poisoned");
        conn.execute(
            "INSERT INTO event_log (event_id, device_id, protocol, kind, payload, at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                event.event_id,
                event.device_id.as_str(),
                event.protocol,
                event.kind,
                payload,
                event.at_ms,
            ],
        )?;
        Ok(())
    }

    /// Most recent `limit` events, newest first.
    pub fn recent_events(&self, limit: u32) -> Result<Vec<DeviceEvent>> {
        let conn = self.conn.lock().expect("store mutex poisoned");
        let mut stmt =
            conn.prepare("SELECT payload FROM event_log ORDER BY seq DESC LIMIT ?1")?;
        let rows = stmt.query_map(params![limit], |row| {
            let payload: String = row.get(0)?;
            Ok(payload)
        })?;
        let mut out = Vec::new();
        for r in rows {
            let payload = r?;
            let ev: DeviceEvent = serde_json::from_str(&payload)?;
            out.push(ev);
        }
        Ok(out)
    }

    fn row_to_device(row: &rusqlite::Row<'_>) -> rusqlite::Result<Device> {
        let id: String = row.get(0)?;
        let protocol: String = row.get(1)?;
        let name: String = row.get(2)?;
        let room: Option<String> = row.get(3)?;
        let caps_json: String = row.get(4)?;
        let state_json: Option<String> = row.get(5)?;

        let capabilities: Vec<Capability> =
            serde_json::from_str(&caps_json).unwrap_or_default();
        let last_state: Option<DeviceState> = match state_json {
            Some(s) => serde_json::from_str(&s).ok(),
            None => None,
        };

        Ok(Device {
            id: DeviceId::new(id),
            protocol,
            name,
            room,
            capabilities,
            last_state,
        })
    }
}

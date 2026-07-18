//! iot-sidecar — BearBrowser's smart-home / IoT control-plane sidecar.
//!
//! Architecture (see README.md):
//!   * `gate`        — the ONE policy engine: every command is evaluated by the
//!                     canonical `agent-control-bridge.py --surface iot`; device
//!                     I/O runs only on `permit`, else fails closed.
//!   * `adapters`    — the `DeviceAdapter` spine (homekit, matter, mdns_ssdp,
//!                     ha_bridge, mqtt, and a real hardware-free `mock`).
//!   * `state`       — SQLite inventory + append-only event log.
//!   * `credentials` — seam to the repo's credential-broker; sidecar stores no secrets.
//!   * `server`      — loopback-only REST + WS API for the cockpit.

// This is a scaffold with deliberate, documented seams that are not yet all
// consumed: the credential-broker transport, the full bridge Decision contract
// (we deserialize every field even where the cockpit does not yet read it), and
// adapter constructors/helpers used once device I/O lands. Silence dead-code
// noise for those; real bugs still surface via other lints.
#![allow(dead_code)]

mod adapters;
mod credentials;
mod gate;
mod model;
mod server;
mod state;

use adapters::AdapterRegistry;
use anyhow::{bail, Context, Result};
use gate::GateConfig;
use server::AppState;
use state::Store;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;

/// Current unix time in epoch milliseconds. Shared helper (used by model + state).
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Minimal runtime configuration, resolved from flags + env.
struct Config {
    /// Loopback port (0 = ephemeral).
    port: u16,
    /// Repo root (to locate the bridge + broker). Defaults to CWD.
    repo_root: PathBuf,
    /// Explicit SQLite path (overrides the default location).
    db_path: Option<PathBuf>,
    /// Use an in-memory store (nothing persisted).
    memory: bool,
}

impl Config {
    fn from_args() -> Result<Self> {
        let mut port: u16 = env_u16("IOT_SIDECAR_PORT").unwrap_or(0);
        let mut repo_root = std::env::var_os("BEARBROWSER_REPO_ROOT")
            .map(PathBuf::from)
            .unwrap_or(std::env::current_dir()?);
        let mut db_path: Option<PathBuf> =
            std::env::var_os("IOT_SIDECAR_DB").map(PathBuf::from);
        let mut memory = false;

        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--port" => {
                    port = args
                        .next()
                        .context("--port needs a value")?
                        .parse()
                        .context("invalid --port")?;
                }
                "--repo-root" => {
                    repo_root = PathBuf::from(args.next().context("--repo-root needs a value")?);
                }
                "--db" => {
                    db_path = Some(PathBuf::from(args.next().context("--db needs a value")?));
                    memory = false;
                }
                "--memory" => {
                    memory = true;
                }
                "-h" | "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                other => bail!("unknown argument: {other} (try --help)"),
            }
        }
        Ok(Config {
            port,
            repo_root,
            db_path,
            memory,
        })
    }
}

fn env_u16(key: &str) -> Option<u16> {
    std::env::var(key).ok().and_then(|v| v.parse().ok())
}

fn print_help() {
    println!(
        "iot-sidecar — BearBrowser loopback IoT control-plane sidecar\n\n\
         USAGE:\n  iot-sidecar [--port N] [--repo-root DIR] [--db PATH | --memory]\n\n\
         OPTIONS:\n  \
         --port N          Loopback port (default 0 = ephemeral). Binds 127.0.0.1 only.\n  \
         --repo-root DIR   BearBrowser repo root (locates agent-control-bridge.py). Default: CWD.\n  \
         --db PATH         SQLite store path. Default: <repo-root>/runtime/iot-sidecar.db\n  \
         --memory          Use an in-memory store (nothing persisted).\n\n\
         ENV: IOT_SIDECAR_PORT, BEARBROWSER_REPO_ROOT, IOT_SIDECAR_DB\n"
    );
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "iot_sidecar=info".into()),
        )
        .with_writer(std::io::stderr) // logs to stderr, never the network
        .init();

    let cfg = Config::from_args()?;

    // Verify the canonical bridge is present — refuse to run ungoverned.
    let gate_cfg = GateConfig::from_repo_root(&cfg.repo_root);
    if !gate_cfg.bridge_path.exists() {
        bail!(
            "canonical policy bridge not found at {} — pass --repo-root pointing at the \
             BearBrowser repo. The sidecar refuses to run without its policy engine.",
            gate_cfg.bridge_path.display()
        );
    }

    // State store.
    let store = if cfg.memory {
        Store::open_in_memory()?
    } else {
        let path = cfg
            .db_path
            .clone()
            .unwrap_or_else(|| cfg.repo_root.join("runtime").join("iot-sidecar.db"));
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        Store::open(&path).with_context(|| format!("opening store at {}", path.display()))?
    };

    let (events, _rx) = broadcast::channel(1024);
    let state = AppState {
        registry: AdapterRegistry::with_defaults(),
        store,
        gate: Arc::new(gate_cfg),
        events,
    };

    // Loopback-only bind.
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), cfg.port);
    server::serve(addr, state).await
}

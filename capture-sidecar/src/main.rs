//! capture-sidecar — BearBrowser network-visibility sidecar.
//!
//! Loopback-only REST+WS server providing three governed surfaces ported from
//! the native macOS shell: session packet capture, a live connection map, and a
//! per-domain firewall. Every side effect is classified by the canonical
//! `scripts/agent-control-bridge.py --surface capture` engine — this binary
//! reimplements NO policy and refuses to start if the bridge is absent.

mod bpf;
mod capture;
mod firewall;
mod gate;
mod geo;
mod model;
mod netmap;
mod netmon;
mod server;

use firewall::Firewall;
use gate::GateConfig;
use netmap::NetworkMonitor;
use server::AppState;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;

struct Config {
    port: u16,
    repo_root: PathBuf,
    state_dir: PathBuf,
    save_dir: PathBuf,
}

impl Config {
    fn from_args() -> anyhow::Result<Config> {
        let mut port: u16 = std::env::var("CAPTURE_SIDECAR_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let mut repo_root = std::env::var("BEARBROWSER_REPO_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|_| std::env::current_dir().unwrap_or_default());
        let mut state_dir = std::env::var("CAPTURE_SIDECAR_STATE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| default_state_dir());

        let args: Vec<String> = std::env::args().collect();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--port" => {
                    i += 1;
                    port = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(port);
                }
                "--repo-root" => {
                    i += 1;
                    if let Some(v) = args.get(i) {
                        repo_root = PathBuf::from(v);
                    }
                }
                "--state" => {
                    i += 1;
                    if let Some(v) = args.get(i) {
                        state_dir = PathBuf::from(v);
                    }
                }
                other => anyhow::bail!("unknown argument: {other}"),
            }
            i += 1;
        }

        // Captures default to the user's Desktop (as the shell did), falling
        // back to the state dir when there's no home.
        let save_dir = dirs_desktop().unwrap_or_else(|| state_dir.clone());

        Ok(Config {
            port,
            repo_root,
            state_dir,
            save_dir,
        })
    }
}

fn default_state_dir() -> PathBuf {
    // ~/.local/share/BearBrowser/capture (unix) — a stable per-user location.
    if let Some(home) = home_dir() {
        home.join(".local/share/BearBrowser/capture")
    } else {
        std::env::temp_dir().join("bearbrowser-capture")
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn dirs_desktop() -> Option<PathBuf> {
    home_dir().map(|h| h.join("Desktop")).filter(|p| p.is_dir())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CAPTURE_SIDECAR_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let cfg = Config::from_args()?;

    // ONE-ENGINE invariant: refuse to run ungoverned. If the canonical bridge is
    // not present under repo-root, there is no policy engine to consult — a
    // capture sidecar that ran anyway would be an unclassified side-effect
    // surface, exactly what the architecture forbids.
    let bridge = cfg.repo_root.join("scripts").join("agent-control-bridge.py");
    if !bridge.is_file() {
        anyhow::bail!(
            "refusing to start: canonical policy bridge not found at {}. \
             Pass --repo-root pointing at the BearBrowser checkout.",
            bridge.display()
        );
    }

    std::fs::create_dir_all(&cfg.state_dir).ok();
    let (events, _) = broadcast::channel(1024);
    let firewall = Arc::new(Firewall::load(Some(cfg.state_dir.join("firewall.json"))));
    let monitor = Arc::new(NetworkMonitor::new(2048));
    let scope: netmon::SharedScope =
        Arc::new(std::sync::RwLock::new(model::Scope::default()));
    // Local IP-intelligence databases (geo + ASN). Dev: capture-sidecar/geoip;
    // override with CAPTURE_SIDECAR_GEOIP; packaged builds stage them alongside.
    let geoip_dir = std::env::var("CAPTURE_SIDECAR_GEOIP")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| cfg.repo_root.join("capture-sidecar/geoip"));
    let geo = Arc::new(geo::Geo::load(&geoip_dir));

    // The live connection monitor — the real, no-root network surface.
    netmon::spawn(monitor.clone(), firewall.clone(), geo.clone(), events.clone(), scope.clone());

    let state = AppState {
        gate: Arc::new(GateConfig::from_repo_root(&cfg.repo_root)),
        firewall,
        monitor,
        events,
        session: Arc::new(tokio::sync::Mutex::new(None)),
        save_dir: cfg.save_dir,
        scope,
        geo,
    };

    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), cfg.port);

    tokio::select! {
        r = server::serve(addr, state) => r?,
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("shutting down");
        }
    }
    Ok(())
}

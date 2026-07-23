//! Session packet capture. Detects an engine (dumpcap > tshark > tcpdump),
//! spawns it on the "any" interface, streams parsed lines to the event bus, and
//! buffers output so it can be saved. Ported from the shell's BBPacketCapture,
//! extended with dumpcap (true pcapng) and cross-platform binary search.

use crate::model::{Engine, SidecarEvent};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{broadcast, Mutex};

/// Candidate binary paths per engine, in preference order. Covers Homebrew
/// (arm64 + intel), system, common Linux, and Windows (Wireshark install dir).
fn candidates() -> Vec<(Engine, &'static str)> {
    vec![
        // dumpcap — writes real pcapng; best fidelity.
        (Engine::Dumpcap, "/opt/homebrew/bin/dumpcap"),
        (Engine::Dumpcap, "/usr/local/bin/dumpcap"),
        (Engine::Dumpcap, "/usr/bin/dumpcap"),
        (Engine::Dumpcap, r"C:\Program Files\Wireshark\dumpcap.exe"),
        // tshark — parsed fields.
        (Engine::Tshark, "/opt/homebrew/bin/tshark"),
        (Engine::Tshark, "/usr/local/bin/tshark"),
        (Engine::Tshark, "/usr/bin/tshark"),
        (Engine::Tshark, r"C:\Program Files\Wireshark\tshark.exe"),
        // tcpdump — always-present fallback on unix.
        (Engine::Tcpdump, "/opt/homebrew/bin/tcpdump"),
        (Engine::Tcpdump, "/usr/local/bin/tcpdump"),
        (Engine::Tcpdump, "/usr/sbin/tcpdump"),
        (Engine::Tcpdump, "/usr/bin/tcpdump"),
    ]
}

/// The detected engine + its absolute binary path.
#[derive(Clone, Debug)]
pub struct Detected {
    pub engine: Engine,
    pub binary: PathBuf,
}

/// First installed + executable engine binary, or None (the panel then shows
/// the "install Wireshark / grant capture perms" guidance, like the shell).
pub fn detect() -> Option<Detected> {
    for (engine, path) in candidates() {
        let p = PathBuf::from(path);
        if is_executable(&p) {
            return Some(Detected { engine, binary: p });
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(p: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(p: &std::path::Path) -> bool {
    p.is_file()
}

/// Build the engine argv for a whole-session capture on "any". `pcap_out` is
/// Some only for dumpcap (real pcapng); tshark/tcpdump stream text we buffer.
/// `host` optionally narrows to one endpoint (mirrors the shell's host filter).
fn argv(engine: Engine, host: Option<&str>, pcap_out: Option<&PathBuf>) -> Vec<String> {
    let s = |x: &str| x.to_string();
    match engine {
        Engine::Dumpcap => {
            // -i any -w <file> ; -f capture filter narrows to a host if given.
            let mut a = vec![s("-i"), s("any"), s("-w")];
            a.push(pcap_out.map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| s("-")));
            if let Some(h) = host {
                a.push(s("-f"));
                a.push(format!("host {h}"));
            }
            a
        }
        Engine::Tshark => {
            let mut a = vec![s("-i"), s("any")];
            if let Some(h) = host {
                a.push(s("-Y"));
                a.push(format!("ip.host contains \"{h}\""));
            }
            a.extend([
                s("-T"), s("fields"),
                s("-e"), s("frame.time_relative"),
                s("-e"), s("ip.src"),
                s("-e"), s("ip.dst"),
                s("-e"), s("tcp.dstport"),
                s("-e"), s("frame.len"),
                s("-E"), s("separator= | "),
            ]);
            a
        }
        Engine::Tcpdump => {
            let mut a = vec![s("-l"), s("-n"), s("-i"), s("any")];
            match host {
                Some(h) => {
                    a.push(s("host"));
                    a.push(h.to_string());
                }
                None => a.extend([s("port"), s("443"), s("or"), s("port"), s("80")]),
            }
            a
        }
    }
}

/// A running capture. Dropping/stopping it terminates the child.
pub struct Session {
    pub engine: Engine,
    pub pcap_path: Option<PathBuf>,
    child: Child,
    /// Text buffer for engines that stream to stdout (tshark/tcpdump).
    pub buffer: Arc<Mutex<String>>,
}

impl Session {
    /// Spawn the engine and pump each stdout line onto `bus` as a Packet event.
    /// For dumpcap the packets go to the pcap file; we still surface a heartbeat.
    pub fn start(
        det: &Detected,
        host: Option<&str>,
        pcap_path: Option<PathBuf>,
        bus: broadcast::Sender<SidecarEvent>,
    ) -> std::io::Result<Session> {
        let args = argv(det.engine, host, pcap_path.as_ref());
        let mut cmd = Command::new(&det.binary);
        cmd.args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = cmd.spawn()?;

        let buffer = Arc::new(Mutex::new(String::new()));

        // stdout: for tshark/tcpdump this is the packet text; for dumpcap the
        // packets go to the file and stdout is quiet, so we also pump stderr
        // (dumpcap prints "Packets captured: N" progress there).
        if let Some(out) = child.stdout.take() {
            spawn_pump(out, bus.clone(), buffer.clone(), det.engine.writes_pcap());
        }
        if let Some(err) = child.stderr.take() {
            // stderr lines are surfaced but never buffered as capture payload.
            spawn_pump(err, bus.clone(), Arc::new(Mutex::new(String::new())), true);
        }

        let _ = bus.send(SidecarEvent::CaptureState {
            running: true,
            engine: Some(det.engine.label().to_string()),
        });

        Ok(Session {
            engine: det.engine,
            pcap_path,
            child,
            buffer,
        })
    }

    pub async fn stop(mut self, bus: &broadcast::Sender<SidecarEvent>) {
        let _ = self.child.start_kill();
        let _ = self.child.wait().await;
        let _ = bus.send(SidecarEvent::CaptureState {
            running: false,
            engine: Some(self.engine.label().to_string()),
        });
    }

    /// Save the capture. dumpcap already wrote a pcapng to `pcap_path`; for the
    /// text engines we flush the buffer to `dest`. Returns the written path.
    pub async fn save(&self, dest: &PathBuf) -> std::io::Result<PathBuf> {
        if let Some(pcap) = &self.pcap_path {
            if pcap.exists() {
                std::fs::copy(pcap, dest)?;
                return Ok(dest.clone());
            }
        }
        let text = self.buffer.lock().await.clone();
        std::fs::write(dest, text)?;
        Ok(dest.clone())
    }
}

fn spawn_pump(
    reader: impl tokio::io::AsyncRead + Unpin + Send + 'static,
    bus: broadcast::Sender<SidecarEvent>,
    buffer: Arc<Mutex<String>>,
    buffer_is_noop: bool,
) {
    tokio::spawn(async move {
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.is_empty() {
                continue;
            }
            if !buffer_is_noop {
                let mut b = buffer.lock().await;
                b.push_str(&line);
                b.push('\n');
            }
            // A closed bus (no subscribers) is fine — we keep buffering.
            let _ = bus.send(SidecarEvent::Packet { line });
        }
    });
}

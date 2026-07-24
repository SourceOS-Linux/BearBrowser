//! Raw-capture capability: detect whether we can actually open a BPF device,
//! and (macOS) install the one-time ChmodBPF privileged helper so dumpcap/tshark
//! can capture as a normal user — the same mechanism Wireshark's installer uses.
//! This is what turns the capture button from a paper tiger into a real feature.

/// Can we actually capture right now? On macOS this means a /dev/bpf* device is
/// openable by us (true only after ChmodBPF + group membership are in place).
/// On other platforms we're optimistic — a failed start reports the real error.
pub fn can_capture() -> bool {
    #[cfg(target_os = "macos")]
    {
        for i in 0..8 {
            if std::fs::OpenOptions::new()
                .read(true)
                .open(format!("/dev/bpf{i}"))
                .is_ok()
            {
                return true;
            }
        }
        false
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Install the one-time capture-permission helper. macOS: creates the
/// `access_bpf` group, adds the user, installs a launchd ChmodBPF daemon that
/// grants that group access to /dev/bpf* at boot, and runs it once — all behind
/// a single admin prompt. Returns human instructions on success, or a manual
/// fallback command on failure/cancel.
pub async fn enable() -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        use tokio::process::Command;
        let user = std::env::var("USER").unwrap_or_default();
        let script = format!(
            r#"#!/bin/sh
set -e
GROUP=access_bpf
if ! dscl . -read /Groups/$GROUP >/dev/null 2>&1; then dseditgroup -o create $GROUP; fi
dseditgroup -o edit -a "{user}" -t user $GROUP || true
SUPPORT="/Library/Application Support/BearBrowser/ChmodBPF"
mkdir -p "$SUPPORT"
cat > "$SUPPORT/ChmodBPF" <<'EOS'
#!/bin/sh
if ! dscl . -read /Groups/access_bpf >/dev/null 2>&1; then dseditgroup -o create access_bpf; fi
for dev in /dev/bpf*; do chgrp access_bpf "$dev" 2>/dev/null || true; chmod g+rw "$dev" 2>/dev/null || true; done
EOS
chmod +x "$SUPPORT/ChmodBPF"
PLIST=/Library/LaunchDaemons/ai.socioprophet.bearbrowser.ChmodBPF.plist
cat > "$PLIST" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>ai.socioprophet.bearbrowser.ChmodBPF</string>
<key>RunAtLoad</key><true/>
<key>ProgramArguments</key><array><string>/Library/Application Support/BearBrowser/ChmodBPF/ChmodBPF</string></array>
</dict></plist>
EOP
launchctl load "$PLIST" 2>/dev/null || true
"$SUPPORT/ChmodBPF"
"#
        );
        let path = std::env::temp_dir().join("bb-chmodbpf-install.sh");
        std::fs::write(&path, script).map_err(|e| e.to_string())?;
        let osa = format!(
            "do shell script \"/bin/sh {}\" with administrator privileges \
             with prompt \"BearBrowser needs one-time permission to capture network packets.\"",
            path.display()
        );
        let out = Command::new("osascript")
            .arg("-e")
            .arg(osa)
            .output()
            .await
            .map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok("Capture enabled. Quit and reopen BearBrowser once so it inherits \
                the new capture permission."
                .to_string())
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            Err(format!(
                "Admin prompt not completed ({}). To enable manually, run in Terminal:\n  sudo /bin/sh {}",
                err.trim(),
                path.display()
            ))
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("Automatic enable is macOS-only. On Linux, add yourself to the \
             'wireshark' group and grant dumpcap CAP_NET_RAW \
             (sudo dpkg-reconfigure wireshark-common; sudo usermod -aG wireshark $USER)."
            .to_string())
    }
}

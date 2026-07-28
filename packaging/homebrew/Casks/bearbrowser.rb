cask "bearbrowser" do
  version "150.0.1"
  # TODO(release): replace with `shasum -a 256` of the published DMG before merge.
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/SourceOS-Linux/BearBrowser/releases/download/v#{version}/BearBrowser-#{version}-macos.dmg",
      verified: "github.com/SourceOS-Linux/BearBrowser/"
  name "BearBrowser"
  desc "Sovereign, privacy-first Firefox fork with a live network monitor and honeypot"
  homepage "https://github.com/SourceOS-Linux/BearBrowser"

  # BearBrowser is a LibreWolf-mirror Firefox 150 fork: hardened anti-fingerprinting,
  # BearNet (a built-in loopback network monitor + world map + OSINT), and BearTrap
  # (a fingerprint-probe honeypot that also blocks canary-token exfiltration).
  app "BearBrowser.app"

  caveats <<~EOS
    BearBrowser is currently shipped UNSIGNED (no paid Apple Developer cert yet).
    Homebrew removes the download quarantine on install, so `brew` launches it fine.
    If macOS still blocks it, right-click the app and choose Open, or run:
      xattr -dr com.apple.quarantine "#{appdir}/BearBrowser.app"
  EOS
end

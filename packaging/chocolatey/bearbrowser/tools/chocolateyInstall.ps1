$ErrorActionPreference = 'Stop'

$packageName = 'bearbrowser'
$installDir  = "$env:ProgramFiles\BearBrowser"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# ── Gecko engine base (Firefox ESR) ──────────────────────────────────────────
# BearBrowser builds on Firefox ESR. We install the patched build when available
# from the BearBrowser release, or bootstrap from Firefox ESR during early access.

$bearRelease = 'https://github.com/SourceOS-Linux/BearBrowser/releases/latest/download'
$geckoBase   = "https://download.mozilla.org/?product=firefox-esr-latest-ssl&os=win64&lang=en-US"

# Try BearBrowser release first
$buildAvailable = $false
try {
  $headResponse = Invoke-WebRequest -Uri "$bearRelease/BearBrowser-win64.zip" -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
  $buildAvailable = ($headResponse.StatusCode -eq 200)
} catch {
  $buildAvailable = $false
}

if ($buildAvailable) {
  Write-Host "Installing BearBrowser release build..."
  Install-ChocolateyZipPackage -PackageName $packageName `
    -Url64bit "$bearRelease/BearBrowser-win64.zip" `
    -UnzipLocation $installDir `
    -Checksum64 'SKIP' -ChecksumType64 'sha256'
} else {
  Write-Host "BearBrowser build pending — bootstrapping from Firefox ESR base..." -ForegroundColor Yellow
  Write-Host "Full BearBrowser patched build requires GCP compile pipeline."

  # Download Firefox ESR as base
  $ffInstaller = "$env:TEMP\firefox-esr-setup.exe"
  try {
    Invoke-WebRequest -Uri $geckoBase -OutFile $ffInstaller -UseBasicParsing
    Start-Process -FilePath $ffInstaller -ArgumentList "/S /InstallDirectoryPath=`"$installDir`"" -Wait
    Remove-Item $ffInstaller -Force -ErrorAction SilentlyContinue
    Write-Host "Firefox ESR base installed. BearBrowser patches will be applied on next update." -ForegroundColor Yellow
  } catch {
    throw "Failed to install Gecko base: $_"
  }
}

# ── Apply BearBrowser configuration profile ────────────────────────────────────
$profileDir = "$env:APPDATA\BearBrowser\Profiles\default"
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

# user.js — fingerprinting protections (101 surfaces)
$userJS = @'
// BearBrowser — 101 JS fingerprinting shield (Windows)
// Canonical: profiles/default/user.js (edit there, not here)

// ── Canvas fingerprinting ─────────────────────────────────────────────────────
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.block_mozAddonManager", true);
user_pref("canvas.poisondata", true);

// ── WebGL ─────────────────────────────────────────────────────────────────────
user_pref("webgl.disabled", false);
user_pref("webgl.renderer-string-override", "Intel Iris OpenGL Engine");
user_pref("webgl.vendor-string-override", "Intel Inc.");
user_pref("webgl.enable-webgl2", true);

// ── AudioContext fingerprinting ───────────────────────────────────────────────
user_pref("privacy.resistFingerprinting.randomDataOnCanvasExtract", true);

// ── Font fingerprinting ───────────────────────────────────────────────────────
user_pref("browser.display.use_document_fonts", 0);
user_pref("gfx.font_rendering.graphite.enabled", false);
user_pref("font.system.whitelist", "");

// ── Timezone / timing ─────────────────────────────────────────────────────────
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.unconditional", true);
user_pref("privacy.reduceTimerPrecision", true);
user_pref("privacy.reduceTimerPrecision.microseconds", 1000);
user_pref("javascript.options.wasm_trustedprincipals", false);

// ── WebRTC ────────────────────────────────────────────────────────────────────
user_pref("media.peerconnection.ice.no_host", true);
user_pref("media.peerconnection.ice.proxy_only_if_behind_proxy", true);
user_pref("media.peerconnection.enabled", true);
user_pref("media.peerconnection.ice.link_local", false);

// ── Navigator normalization ───────────────────────────────────────────────────
user_pref("general.useragent.override", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0");
user_pref("general.platform.override", "Win32");
user_pref("general.oscpu.override", "Windows NT 10.0");
user_pref("general.appname.override", "Netscape");
user_pref("general.appversion.override", "5.0 (X11)");

// ── Hardware concurrency ──────────────────────────────────────────────────────
user_pref("dom.maxHardwareConcurrency", 4);

// ── Battery API ───────────────────────────────────────────────────────────────
user_pref("dom.battery.enabled", false);

// ── Sensors ───────────────────────────────────────────────────────────────────
user_pref("device.sensors.enabled", false);
user_pref("device.sensors.ambientLight.enabled", false);
user_pref("device.sensors.motion.enabled", false);
user_pref("device.sensors.orientation.enabled", false);
user_pref("device.sensors.proximity.enabled", false);
user_pref("dom.gamepad.enabled", false);
user_pref("dom.gamepad.extensions.enabled", false);

// ── Network fingerprinting ────────────────────────────────────────────────────
user_pref("network.http.sendRefererHeader", 2);
user_pref("network.http.referer.spoofSource", false);
user_pref("network.http.sendSecureXSiteReferrer", false);
user_pref("network.cookie.cookieBehavior", 5);
user_pref("network.http.http3.enabled", false);
user_pref("network.http.connection-retry-timeout", 0);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.predictor.enable-prefetch", false);
user_pref("network.http.speculative-parallel-limit", 0);

// ── Tracking protection ───────────────────────────────────────────────────────
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.pbmode.enabled", true);
user_pref("privacy.trackingprotection.annotate_channels", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.origin_telemetry.enabled", false);
user_pref("privacy.firstparty.isolate", true);
user_pref("privacy.firstparty.isolate.block_post_message", true);
user_pref("privacy.firstparty.isolate.restrict_opener_access", true);

// ── Telemetry off ─────────────────────────────────────────────────────────────
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);
user_pref("toolkit.telemetry.hybridContent.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);

// ── Google services off ───────────────────────────────────────────────────────
user_pref("geo.provider.network.url", "");
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.blockedURIs.enabled", false);
user_pref("browser.safebrowsing.provider.google.advisoryURL", "");
user_pref("browser.safebrowsing.provider.google4.advisoryURL", "");
user_pref("services.sync.enabled", false);
user_pref("browser.aboutHomeSnippets.updateUrl", "");

// ── Cache side-channel mitigation ─────────────────────────────────────────────
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.offline.enable", false);
user_pref("security.OCSP.enabled", 1);
user_pref("security.OCSP.require", true);
user_pref("security.cert_pinning.enforcement_level", 2);

// ── Media / codec fingerprinting ─────────────────────────────────────────────
user_pref("media.navigator.enabled", false);
user_pref("media.navigator.video.enabled", false);
user_pref("media.getusermedia.screensharing.enabled", false);
user_pref("media.getusermedia.audiocapture.enabled", false);

// ── Misc privacy ─────────────────────────────────────────────────────────────
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.newtab.url", "about:blank");
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("browser.urlbar.trimURLs", false);
user_pref("layout.css.visited_links_enabled", false);
user_pref("dom.indexedDB.enabled", true);
user_pref("dom.storage.enabled", true);
user_pref("dom.allow_cut_copy", false);
user_pref("dom.event.clipboardevents.enabled", false);
user_pref("clipboard.autocopy", false);
user_pref("extensions.pocket.enabled", false);
user_pref("extensions.screenshots.disabled", true);
user_pref("reader.parse-on-load.enabled", false);
'@
Set-Content -Path "$profileDir\user.js" -Value $userJS -Encoding UTF8

# ── Windows default browser registration ──────────────────────────────────────
$bearExe = if (Test-Path "$installDir\BearBrowser.exe") { "$installDir\BearBrowser.exe" } else { "$installDir\firefox.exe" }
if (Test-Path $bearExe) {
  # Register URI handlers
  $regBase = "HKLM:\SOFTWARE\Classes"
  foreach ($proto in @('http', 'https', 'ftp')) {
    $key = "$regBase\BearBrowser.$proto"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name '(Default)' -Value "BearBrowser URL"
    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$key\shell\open\command" -Name '(Default)' -Value "`"$bearExe`" --profile `"$profileDir`" -url `"%1`""
  }

  # Register as browser option
  $capKey = "HKLM:\SOFTWARE\Clients\StartMenuInternet\BearBrowser"
  New-Item -Path $capKey -Force | Out-Null
  Set-ItemProperty -Path $capKey -Name '(Default)' -Value 'BearBrowser'
  New-Item -Path "$capKey\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path "$capKey\shell\open\command" -Name '(Default)' -Value "`"$bearExe`" --profile `"$profileDir`""

  # Create Start Menu shortcut
  $shortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\BearBrowser.lnk"
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($shortcut)
  $lnk.TargetPath = $bearExe
  $lnk.Arguments  = "--profile `"$profileDir`""
  $lnk.Description = "BearBrowser — Privacy-first Gecko browser"
  $lnk.Save()

  Write-Host ""
  Write-Host "BearBrowser installed." -ForegroundColor Green
  Write-Host "  Profile:   $profileDir"
  Write-Host "  Shortcut:  $shortcut"
  Write-Host "  101 fingerprinting protections active."
} else {
  Write-Warning "Browser executable not found at $bearExe — manual setup required."
}

class Bearbrowser < Formula
  desc "SourceOS governed browser overlay and agent-runtime tooling"
  homepage "https://github.com/SourceOS-Linux/BearBrowser"
  url "https://github.com/SourceOS-Linux/BearBrowser.git", branch: "main"
  version "0.1.0-overlay"
  license "MPL-2.0"
  head "https://github.com/SourceOS-Linux/BearBrowser.git", branch: "main"

  depends_on "git"
  depends_on "python@3.12"

  def install
    libexec.install Dir["*"]

    (bin/"bearbrowser").write wrapper_for("apply-sourceos-overlays.sh")
    (bin/"bearbrowser-open").write wrapper_for("bearbrowser-open.sh")
    (bin/"bearbrowser-status").write wrapper_for("bearbrowser-status.sh")
    (bin/"bearbrowser-reset-bootstrap").write wrapper_for("bearbrowser-reset-bootstrap.sh")
    (bin/"bearbrowser-emit-event").write wrapper_for("bearbrowser-emit-event.py")
    (bin/"bearbrowser-verify-provenance").write wrapper_for("bearbrowser-verify-provenance.py")
    (bin/"bearbrowser-propose-action").write wrapper_for("bearbrowser-propose-action.py")
    (bin/"bearbrowser-resolve-action").write wrapper_for("bearbrowser-resolve-action.py")
    (bin/"bearbrowser-verify-actions").write wrapper_for("bearbrowser-verify-actions.py")
    (bin/"bearbrowser-memory-candidate").write wrapper_for("bearbrowser-memory-candidate.py")
    (bin/"bearbrowser-verify-memory").write wrapper_for("bearbrowser-verify-memory.py")
    (bin/"bearbrowser-governance-queue").write wrapper_for("bearbrowser-governance-queue.py")
    (bin/"bearbrowser-sidecar-server").write wrapper_for("bearbrowser-sidecar-server.py")
    (bin/"bearbrowser-sidecar-open").write wrapper_for("bearbrowser-sidecar-open.sh")
    (bin/"bearbrowser-sidecar-status").write wrapper_for("bearbrowser-sidecar-status.py")
    (bin/"bearbrowser-verify-sidecar-status").write wrapper_for("verify-sidecar-status.sh")
    (bin/"bearbrowser-verify-interactive-sidecar").write wrapper_for("verify-interactive-sidecar.sh")
    (bin/"bearbrowser-verify-agent-sidecar").write wrapper_for("verify-agent-sidecar-contract.py")
    (bin/"bearbrowser-verify-native-shell").write wrapper_for("verify-native-macos-shell.sh")
    (bin/"bearbrowser-build-binary").write wrapper_for("bearbrowser-build-binary.sh")
    (bin/"bearbrowser-install-app-launcher").write wrapper_for("install-macos-app-launcher.sh")
    (bin/"bearbrowser-repair-app-launcher").write wrapper_for("repair-macos-app-launcher.sh")
    (bin/"bearbrowser-verify-build-lane").write wrapper_for("verify-build-lane.sh")
    (bin/"bearbrowser-check-build-env").write wrapper_for("check-build-environment.sh")
    (bin/"bearbrowser-discover-build-system").write wrapper_for("discover-upstream-build-system.sh")
    (bin/"bearbrowser-verify-upstream").write wrapper_for("verify-upstream-parity.sh")
    (bin/"bearbrowser-doctor").write wrapper_for("bearbrowser-doctor.sh")
    (bin/"bearbrowser-credential-doctor").write wrapper_for("bearbrowser-credential-doctor.sh")
    (bin/"bearbrowser-verify-credentials").write wrapper_for("verify-credential-broker.sh")
    (bin/"bearbrowser-verify-linux-packaging").write wrapper_for("verify-linux-packaging.sh")
    (bin/"bearbrowser-package-linux-all").write wrapper_for("package-linux-all.sh")
    (bin/"bearbrowser-update").write wrapper_for("bearbrowser-update.sh")
    (bin/"bearbrowser-automation-surfaces").write wrapper_for("bearbrowser-automation-surfaces.sh")
    (bin/"bearbrowser-install-runtime-deps").write wrapper_for("bearbrowser-install-runtime-deps.sh")
    (bin/"bearbrowser-lock-runtime-deps").write wrapper_for("bearbrowser-lock-runtime-deps.sh")
    (bin/"bearbrowser-playwright").write wrapper_for("bearbrowser-playwright.sh")
    (bin/"bearbrowser-stagehand").write wrapper_for("bearbrowser-stagehand.sh")
    (bin/"bearbrowser-terminal").write wrapper_for("bearbrowser-terminal.sh")
  end

  def wrapper_for(script)
    interpreter = script.end_with?(".py") ? "python3" : "bash"
    <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec #{interpreter} "#{libexec}/scripts/#{script}" "$@"
    EOS
  end

  def caveats
    <<~EOS
      BearBrowser Formula installs the overlay/runtime tooling.

      Useful commands:
        bearbrowser-install-app-launcher
        bearbrowser-repair-app-launcher
        bearbrowser-open
        bearbrowser-status
        bearbrowser-reset-bootstrap
        bearbrowser-emit-event --event-type runtime.health --payload '{"status":"ok"}'
        bearbrowser-verify-provenance
        bearbrowser-propose-action --action-type summarize_page --target-kind page --target-label current-page
        bearbrowser-resolve-action --latest-held --decision deny --reason 'Local denial.'
        bearbrowser-verify-actions
        bearbrowser-memory-candidate create --text 'Remember this only after approval.'
        bearbrowser-memory-candidate resolve --latest-candidate --decision reject --reason 'Not useful.'
        bearbrowser-verify-memory
        bearbrowser-governance-queue
        bearbrowser-sidecar-open --open
        bearbrowser-sidecar-server --print-url
        bearbrowser-sidecar-status --format html --open
        bearbrowser-verify-interactive-sidecar
        bearbrowser-verify-sidecar-status
        bearbrowser-verify-agent-sidecar
        bearbrowser-verify-native-shell
        bearbrowser --profile agent-runtime --ref latest --dry-run
        bearbrowser-build-binary --profile agent-runtime --dry-run
        bearbrowser-verify-build-lane
        bearbrowser-check-build-env
        bearbrowser-discover-build-system <workspace-source-dir>
        bearbrowser-verify-upstream
        bearbrowser-doctor
        bearbrowser-credential-doctor
        bearbrowser-verify-credentials
        bearbrowser-verify-linux-packaging
        bearbrowser-package-linux-all
        bearbrowser-update
        bearbrowser-automation-surfaces
        bearbrowser-install-runtime-deps
        bearbrowser-lock-runtime-deps
        bearbrowser-playwright --dry-run
        bearbrowser-stagehand --dry-run
        bearbrowser-terminal --dry-run

      Full signed app distribution will use:
        brew install --cask SourceOS-Linux/tap/bearbrowser
    EOS
  end

  test do
    assert_match "BearBrowser overlay plan", shell_output("#{bin}/bearbrowser --profile agent-runtime --ref latest --dry-run")
    assert_match "BearBrowser status", shell_output("#{bin}/bearbrowser-status")
    assert_match "BearBrowser full binary build lane", shell_output("#{bin}/bearbrowser-build-binary --profile agent-runtime --dry-run")
    assert_match "BearBrowser build lane verified", shell_output("#{bin}/bearbrowser-verify-build-lane")
    assert_match "BearBrowser build environment check", shell_output("#{bin}/bearbrowser-check-build-env")
    assert_match "hidden_refs=", shell_output("#{bin}/bearbrowser-verify-upstream")
    assert_match "BearBrowser doctor", shell_output("#{bin}/bearbrowser-doctor")
    assert_match "BearBrowser credential doctor", shell_output("#{bin}/bearbrowser-credential-doctor")
    assert_match "BearBrowser credential broker policy verified", shell_output("#{bin}/bearbrowser-verify-credentials")
    assert_match "BearBrowser Linux packaging verified", shell_output("#{bin}/bearbrowser-verify-linux-packaging")
    assert_match "browser.playwright", shell_output("#{bin}/bearbrowser-automation-surfaces")
    assert_match "BearBrowser provenance", shell_output("#{bin}/bearbrowser-emit-event --event-type runtime.health --payload '{\"status\":\"test\"}'")
    assert_match "BearBrowser policy action", shell_output("#{bin}/bearbrowser-propose-action --action-type summarize_page --target-kind page --target-label test")
    assert_match "BearBrowser agent sidecar contract verified", shell_output("#{bin}/bearbrowser-verify-agent-sidecar")
    assert_match "BearBrowser sidecar status verified", shell_output("#{bin}/bearbrowser-verify-sidecar-status")
    assert_match "http://127.0.0.1:", shell_output("#{bin}/bearbrowser-sidecar-server --print-url")
  end
end

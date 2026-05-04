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
    (bin/"bearbrowser-build-binary").write wrapper_for("bearbrowser-build-binary.sh")
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
    <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec bash "#{libexec}/scripts/#{script}" "$@"
    EOS
  end

  def caveats
    <<~EOS
      BearBrowser Formula installs the overlay/runtime tooling.

      Useful commands:
        bearbrowser --profile agent-runtime --ref latest --dry-run
        bearbrowser-build-binary --profile agent-runtime --dry-run
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

      Future GUI app distribution will use:
        brew install --cask SourceOS-Linux/tap/bearbrowser
    EOS
  end

  test do
    assert_match "BearBrowser overlay plan", shell_output("#{bin}/bearbrowser --profile agent-runtime --ref latest --dry-run")
    assert_match "BearBrowser full binary build lane", shell_output("#{bin}/bearbrowser-build-binary --profile agent-runtime --dry-run")
    assert_match "hidden_refs=", shell_output("#{bin}/bearbrowser-verify-upstream")
    assert_match "BearBrowser doctor", shell_output("#{bin}/bearbrowser-doctor")
    assert_match "BearBrowser credential doctor", shell_output("#{bin}/bearbrowser-credential-doctor")
    assert_match "BearBrowser credential broker policy verified", shell_output("#{bin}/bearbrowser-verify-credentials")
    assert_match "BearBrowser Linux packaging verified", shell_output("#{bin}/bearbrowser-verify-linux-packaging")
    assert_match "browser.playwright", shell_output("#{bin}/bearbrowser-automation-surfaces")
  end
end

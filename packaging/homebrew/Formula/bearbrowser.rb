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

    (bin/"bearbrowser").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec bash "#{libexec}/scripts/apply-sourceos-overlays.sh" "$@"
    EOS

    (bin/"bearbrowser-verify-upstream").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec bash "#{libexec}/scripts/verify-upstream-parity.sh" "$@"
    EOS

    (bin/"bearbrowser-doctor").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec bash "#{libexec}/scripts/bearbrowser-doctor.sh" "$@"
    EOS

    (bin/"bearbrowser-update").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec bash "#{libexec}/scripts/bearbrowser-update.sh" "$@"
    EOS
  end

  def caveats
    <<~EOS
      BearBrowser Formula installs the overlay/runtime tooling.

      Useful commands:
        bearbrowser --profile agent-runtime --ref latest --dry-run
        bearbrowser-verify-upstream
        bearbrowser-doctor
        bearbrowser-update

      Future GUI app distribution will use:
        brew install --cask SourceOS-Linux/tap/bearbrowser
    EOS
  end

  test do
    assert_match "BearBrowser overlay plan", shell_output("#{bin}/bearbrowser --profile agent-runtime --ref latest --dry-run")
    assert_match "hidden_refs=", shell_output("#{bin}/bearbrowser-verify-upstream")
    assert_match "BearBrowser doctor", shell_output("#{bin}/bearbrowser-doctor")
  end
end

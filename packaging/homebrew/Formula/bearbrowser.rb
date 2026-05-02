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
      exec "#{libexec}/scripts/apply-sourceos-overlays.sh" "$@"
    EOS

    (bin/"bearbrowser-verify-upstream").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail
      exec "#{libexec}/scripts/verify-upstream-parity.sh" "$@"
    EOS
  end

  test do
    assert_match "BearBrowser overlay plan", shell_output("#{bin}/bearbrowser --profile agent-runtime --ref latest --dry-run")
    assert_match "hidden_refs=", shell_output("#{bin}/bearbrowser-verify-upstream")
  end
end

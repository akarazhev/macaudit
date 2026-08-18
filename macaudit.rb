# Copy this into your tap repository as Formula/macaudit.rb, then:
#   brew install akarazhev/tap/macaudit
#
# The url and sha256 for each release are printed in that release's notes.
class Macaudit < Formula
  desc "Read-only macOS audit report: apps, startup items, processes, security"
  homepage "https://github.com/akarazhev/macaudit"
  url "https://github.com/akarazhev/macaudit/releases/download/v1.3/macaudit-1.3.tar.gz"
  sha256 "PASTE_THE_CHECKSUM_FROM_THE_RELEASE_NOTES"
  license "MIT"

  depends_on :macos

  def install
    bin.install "macaudit.sh" => "macaudit"
    doc.install "README.md"
  end

  test do
    assert_match "macaudit #{version}", shell_output("#{bin}/macaudit --version")
    system bin/"macaudit", "--fast", "--redact", "--no-snapshot", "--no-open",
           "-o", testpath/"report.html"
    assert_predicate testpath/"report.html", :exist?
  end
end

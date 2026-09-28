require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Portage::Cli::BrowserProfile::Browsers do
  describe ".binary_for" do
    it "returns the macOS app path when it exists" do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(described_class::MAC_APPS["chrome"]).and_return(true)

      expect(described_class.binary_for("chrome", darwin: true)).to eq(described_class::MAC_APPS["chrome"])
    end

    it "never looks at macOS app paths on a non-darwin machine" do
      expect(File).not_to receive(:exist?).with(described_class::MAC_APPS["chrome"])
      described_class.binary_for("chrome", darwin: false)
    end

    it "falls back to an executable on PATH for Linux-named binaries" do
      Dir.mktmpdir do |dir|
        fake_chrome = File.join(dir, "google-chrome")
        File.write(fake_chrome, "#!/bin/sh\n")
        File.chmod(0o755, fake_chrome)

        expect(described_class.binary_for("chrome", darwin: false, path: dir)).to eq(fake_chrome)
      end
    end

    it "finds nothing for a browser with no candidate installed anywhere" do
      Dir.mktmpdir { |dir| expect(described_class.binary_for("arc", darwin: false, path: dir)).to be_nil }
    end
  end

  describe ".detect" do
    it "returns the first Chromium-family browser with an installed default profile root" do
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, "Library/Application Support/BraveSoftware/Brave-Browser"))

        expect(described_class.detect(home: home)).to eq("brave")
      end
    end

    it "returns nil when nothing is installed" do
      Dir.mktmpdir { |home| expect(described_class.detect(home: home)).to be_nil }
    end
  end
end

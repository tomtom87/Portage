require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::CheckoutHandoff do
  # `Config.new(data: {})` alone still defaults `path:` to the real
  # ~/.portage/config.json — any `#set` call below would write to the
  # developer's actual config file, not a fixture. Pointing every `Config`
  # at a throwaway path keeps that write local to the example.
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }
  let(:url) { "https://shop.example/checkout/chk_1" }

  describe "#auto_open? precedence" do
    it "defaults to false when nothing is configured" do
      expect(described_class.new(config: config).auto_open?).to be false
    end

    it "reads config.json when set" do
      config.set("auto_open_checkout", true)

      expect(described_class.new(config: config).auto_open?).to be true
    end

    it "prefers the env var over config.json" do
      config.set("auto_open_checkout", true)

      with_env("PORTAGE_AUTO_OPEN_CHECKOUT" => "0") do
        expect(described_class.new(config: config).auto_open?).to be false
      end
    end

    it "prefers an explicit override over both the env var and config.json" do
      config.set("auto_open_checkout", false)

      with_env("PORTAGE_AUTO_OPEN_CHECKOUT" => "0") do
        expect(described_class.new(auto_open: true, config: config).auto_open?).to be true
      end
    end
  end

  describe "#call" do
    it "never shells out when auto-open is disabled (the default)" do
      handoff = described_class.new(auto_open: false, config: config)

      expect(handoff).not_to receive(:system)
      expect(handoff.call(url)).to be false
    end

    it "shells out to the platform's open command when enabled" do
      handoff = described_class.new(auto_open: true, config: config)
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin23")
      allow(handoff).to receive(:system).with("open", url).and_return(true)

      expect(handoff.call(url)).to be true
      expect(handoff).to have_received(:system).with("open", url)
    end

    it "refuses to open a non-https checkout_url even when enabled" do
      handoff = described_class.new(auto_open: true, config: config)

      expect(handoff).not_to receive(:system)
      expect(handoff.call("http://shop.example/checkout/chk_1")).to be false
    end

    it "doesn't raise when the shell-out itself fails, and reports it wasn't opened" do
      handoff = described_class.new(auto_open: true, config: config)
      allow(handoff).to receive(:system).and_raise(Errno::ENOENT, "open")

      expect { expect(handoff.call(url)).to be false }.to output(/couldn't open/).to_stderr
    end
  end
end

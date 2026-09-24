require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::HandoffWaitTimeout do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  describe "#resolve" do
    it "defaults to 30 minutes when nothing is configured" do
      expect(described_class.resolve(config: config)).to eq(1800)
    end

    it "reads a plain integer as seconds from config.json" do
      config.set("handoff_wait_timeout", "600")

      expect(described_class.resolve(config: config)).to eq(600)
    end

    it "prefers the env var over config.json" do
      config.set("handoff_wait_timeout", "600")

      with_env("PORTAGE_HANDOFF_WAIT_TIMEOUT" => "45m") do
        expect(described_class.resolve(config: config)).to eq(2700)
      end
    end

    it "prefers an explicit override over both" do
      config.set("handoff_wait_timeout", "600")

      with_env("PORTAGE_HANDOFF_WAIT_TIMEOUT" => "45m") do
        expect(described_class.resolve(override: "10m", config: config)).to eq(600)
      end
    end

    %w[s m h].each do |unit|
      it "parses a #{unit}-suffixed duration" do
        seconds = { "s" => 1, "m" => 60, "h" => 3600 }.fetch(unit)

        expect(described_class.resolve(override: "5#{unit}", config: config)).to eq(5 * seconds)
      end
    end

    it "returns nil (no ceiling) for off" do
      expect(described_class.resolve(override: "off", config: config)).to be_nil
    end

    it "returns nil (no ceiling) for 0" do
      expect(described_class.resolve(override: "0", config: config)).to be_nil
    end

    it "is case-insensitive on off" do
      expect(described_class.resolve(override: "OFF", config: config)).to be_nil
    end

    it "falls back to the default for garbage input" do
      expect(described_class.resolve(override: "banana", config: config)).to eq(1800)
    end
  end
end

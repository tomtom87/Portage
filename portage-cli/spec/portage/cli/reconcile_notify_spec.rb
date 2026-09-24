require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::ReconcileNotify do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  describe "#resolve" do
    it "defaults to webhook only" do
      expect(described_class.resolve(config: config)).to eq(["webhook"])
    end

    it "reads a comma list from config.json" do
      config.set("reconcile_notify", "webhook,macos")

      expect(described_class.resolve(config: config)).to contain_exactly("webhook", "macos")
    end

    it "prefers the env var over config.json" do
      config.set("reconcile_notify", "webhook")

      with_env("PORTAGE_RECONCILE_NOTIFY" => "terminal") do
        expect(described_class.resolve(config: config)).to eq(["terminal"])
      end
    end

    it "prefers an explicit override over both" do
      config.set("reconcile_notify", "webhook")

      with_env("PORTAGE_RECONCILE_NOTIFY" => "terminal") do
        expect(described_class.resolve(override: "macos", config: config)).to eq(["macos"])
      end
    end

    it "drops an unknown channel name" do
      expect(described_class.resolve(override: "webhook,carrier-pigeon", config: config)).to eq(["webhook"])
    end

    it "adds extra channels without duplicating a configured one" do
      expect(described_class.resolve(override: "webhook", config: config, extra: %w[webhook terminal]))
        .to contain_exactly("webhook", "terminal")
    end
  end
end

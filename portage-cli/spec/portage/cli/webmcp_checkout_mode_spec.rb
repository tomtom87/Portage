require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::WebmcpCheckoutMode do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  it "defaults to express_stop" do
    expect(described_class.resolve(config: config)).to eq("express_stop")
  end

  it "reads config.json" do
    config.set("webmcp_checkout_mode", "token")

    expect(described_class.resolve(config: config)).to eq("token")
  end

  it "prefers the env var over config.json" do
    config.set("webmcp_checkout_mode", "token")

    with_env("PORTAGE_WEBMCP_CHECKOUT_MODE" => "express_stop") do
      expect(described_class.resolve(config: config)).to eq("express_stop")
    end
  end

  it "prefers an explicit override over both" do
    config.set("webmcp_checkout_mode", "token")

    with_env("PORTAGE_WEBMCP_CHECKOUT_MODE" => "token") do
      expect(described_class.resolve(override: "express_stop", config: config)).to eq("express_stop")
    end
  end

  it "falls back to the default for an unknown mode" do
    config.set("webmcp_checkout_mode", "nonsense")

    expect(described_class.resolve(config: config)).to eq("express_stop")
  end
end

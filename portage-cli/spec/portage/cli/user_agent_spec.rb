require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::UserAgent do
  # Same reasoning as notifier_spec.rb: point every Config at a throwaway
  # path so a `#set` call here never touches the developer's real
  # ~/.portage/config.json.
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  describe "#value precedence" do
    it "falls back to DEFAULT when nothing is configured" do
      expect(described_class.value(config: config)).to eq(described_class::DEFAULT)
    end

    it "reads config.json when set" do
      config.set("user_agent", "my-agent/1.0")

      expect(described_class.value(config: config)).to eq("my-agent/1.0")
    end

    it "prefers the env var over config.json" do
      config.set("user_agent", "config-agent/1.0")

      with_env("PORTAGE_USER_AGENT" => "env-agent/1.0") do
        expect(described_class.value(config: config)).to eq("env-agent/1.0")
      end
    end
  end

  describe "#headers" do
    it "wraps #value under the User-Agent key" do
      config.set("user_agent", "my-agent/1.0")

      expect(described_class.headers(config: config)).to eq("User-Agent" => "my-agent/1.0")
    end
  end
end

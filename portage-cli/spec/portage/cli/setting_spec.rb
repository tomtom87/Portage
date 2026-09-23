require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Setting do
  # Same reason as checkout_handoff_spec: a Config with no `path:` would
  # write to the developer's real ~/.portage/config.json.
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      with_env("PORTAGE_TEST_SETTING" => nil) { example.run }
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  def resolve(**) = described_class.resolve(env: "PORTAGE_TEST_SETTING", config: config, config_key: "test", **)
  def flag?(**) = described_class.flag?(env: "PORTAGE_TEST_SETTING", config: config, config_key: "test", **)

  describe ".resolve" do
    it "is nil when no level is set" do
      expect(resolve).to be_nil
    end

    it "reads config.json, then lets the env var beat it, then lets an override beat both" do
      config.set("test", "from-config")
      expect(resolve).to eq("from-config")

      with_env("PORTAGE_TEST_SETTING" => "from-env") do
        expect(resolve).to eq("from-env")
        expect(resolve(override: "from-flag")).to eq("from-flag")
      end
    end

    it "treats a blank env var or override as unset, not as a value" do
      config.set("test", "from-config")

      with_env("PORTAGE_TEST_SETTING" => " ") do
        expect(resolve(override: "")).to eq("from-config")
      end
    end

    it "lets an explicit false override win" do
      config.set("test", true)

      expect(resolve(override: false)).to be false
    end
  end

  describe ".flag?" do
    it "reads 1/true/yes in any case as yes, and anything else as no" do
      %w[1 true YES Yes].each do |raw|
        with_env("PORTAGE_TEST_SETTING" => raw) { expect(flag?).to be true }
      end
      %w[0 false no maybe].each do |raw|
        with_env("PORTAGE_TEST_SETTING" => raw) { expect(flag?).to be false }
      end
    end

    it "takes booleans from a flag or config.json as they are" do
      config.set("test", true)
      expect(flag?).to be true
      expect(flag?(override: false)).to be false
    end

    it "is no when nothing is set" do
      expect(flag?).to be false
    end
  end
end

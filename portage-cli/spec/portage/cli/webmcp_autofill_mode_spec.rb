require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::WebmcpAutofillMode do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }

  it "is off by default" do
    expect(described_class.approved?(config: config)).to be(false)
  end

  it "turns on with --autofill's override (true), even with nothing else set" do
    expect(described_class.approved?(override: true, config: config)).to be(true)
  end

  it "turns on with PORTAGE_WEBMCP_AUTOFILL=approve" do
    with_env("PORTAGE_WEBMCP_AUTOFILL" => "approve") do
      expect(described_class.approved?(config: config)).to be(true)
    end
  end

  it "is case-insensitive and trims the env var" do
    with_env("PORTAGE_WEBMCP_AUTOFILL" => " Approve \n") do
      expect(described_class.approved?(config: config)).to be(true)
    end
  end

  it "doesn't turn on for a generic truthy value — only the literal 'approve'" do
    with_env("PORTAGE_WEBMCP_AUTOFILL" => "true") do
      expect(described_class.approved?(config: config)).to be(false)
    end
  end

  it "reads config.json's webmcp_autofill" do
    config.set("webmcp_autofill", "approve")

    expect(described_class.approved?(config: config)).to be(true)
  end

  it "prefers the env var over config.json" do
    config.set("webmcp_autofill", "approve")

    with_env("PORTAGE_WEBMCP_AUTOFILL" => nil) do
      expect(described_class.approved?(config: config)).to be(true)
    end
  end

  it "the --autofill override alone is enough, with no env/config set at all" do
    with_env("PORTAGE_WEBMCP_AUTOFILL" => nil) do
      expect(described_class.approved?(override: true, config: Portage::Cli::Config.new(path: @config_path,
                                                                                        data: {}))).to be(true)
    end
  end
end

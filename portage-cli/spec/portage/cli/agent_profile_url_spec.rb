require "spec_helper"

RSpec.describe Portage::Cli::AgentProfileUrl do
  describe ".resolve" do
    it "returns PORTAGE_AGENT_PROFILE when it's set" do
      with_env("PORTAGE_AGENT_PROFILE" => "https://example.com/agent-profile.json") do
        expect(described_class.resolve).to eq("https://example.com/agent-profile.json")
      end
    end

    it "falls back to the repo's published profile when unset" do
      with_env("PORTAGE_AGENT_PROFILE" => nil) do
        expect(described_class.resolve).to eq(described_class::DEFAULT)
      end
    end

    it "falls back when PORTAGE_AGENT_PROFILE is set but blank" do
      with_env("PORTAGE_AGENT_PROFILE" => "  ") do
        expect(described_class.resolve).to eq(described_class::DEFAULT)
      end
    end
  end
end

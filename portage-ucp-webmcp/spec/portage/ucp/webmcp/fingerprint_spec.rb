require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Fingerprint do
  describe ".names" do
    it "returns tool names sorted, string- or symbol-keyed alike" do
      tools = [{ "name" => "b_tool" }, { name: "a_tool" }]

      expect(described_class.names(tools)).to eq(%w[a_tool b_tool])
    end
  end

  describe ".for" do
    it "is stable regardless of tool order" do
      tools = [{ "name" => "a", "inputSchema" => { "properties" => { "x" => {} } } },
               { "name" => "b", "inputSchema" => {} }]

      expect(described_class.for(tools)).to eq(described_class.for(tools.reverse))
    end

    it "differs when a tool's input schema differs, even with the same tool names" do
      base = [{ "name" => "a", "inputSchema" => { "properties" => { "x" => {} } } }]
      changed = [{ "name" => "a", "inputSchema" => { "properties" => { "x" => {}, "y" => {} } } }]

      expect(described_class.for(base)).not_to eq(described_class.for(changed))
    end

    it "differs when the tool names differ, even with identical schemas" do
      one = [{ "name" => "a", "inputSchema" => {} }]
      other = [{ "name" => "b", "inputSchema" => {} }]

      expect(described_class.for(one)).not_to eq(described_class.for(other))
    end
  end
end

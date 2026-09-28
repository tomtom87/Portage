require "spec_helper"
require "tmpdir"
require "portage/ucp/webmcp"

RSpec.describe Portage::Cli::WebmcpMappings do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "webmcp_mappings.json")
      example.run
    end
  end

  let(:mappings) { described_class.new(path: @path, data: {}) }
  let(:tools) { [{ "name" => "findProducts", "inputSchema" => { "properties" => { "query" => {} } } }] }
  let(:differently_shaped_tools) do
    [{ "name" => "findProducts", "inputSchema" => { "properties" => { "query" => {}, "extra" => {} } } }]
  end

  describe "#lookup" do
    it "is nil when nothing has been confirmed for this fingerprint" do
      expect(mappings.lookup(tools)).to be_nil
    end

    it "returns a confirmed mapping, string-keyed" do
      mappings.confirm!(tools, tool_names: { search_catalog: "findProducts" })

      expect(mappings.lookup(tools)).to eq("search_catalog" => "findProducts")
    end

    it "is shared across any page with the exact same tool fingerprint, not keyed by origin" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" }, origin: "store-a.example")

      expect(mappings.lookup(tools)).to eq("search_catalog" => "findProducts")
    end

    it "doesn't match a page whose tools have the same names but a different input schema" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" })

      expect(mappings.lookup(differently_shaped_tools)).to be_nil
    end
  end

  describe "#confirm!" do
    it "merges onto an existing entry rather than replacing it" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" })
      mappings.confirm!(tools, tool_names: { "create_cart" => "addItemToCart" })

      expect(mappings.lookup(tools)).to eq("search_catalog" => "findProducts", "create_cart" => "addItemToCart")
    end

    it "records every distinct origin it's been confirmed on, as metadata only" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" }, origin: "a.example")
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" }, origin: "b.example")
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" }, origin: "a.example")

      key = Portage::Ucp::WebMcp::Fingerprint.for(tools)
      expect(mappings.to_h[key]["origins"]).to contain_exactly("a.example", "b.example")
    end

    it "persists to disk and reloads" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" })

      reloaded = described_class.load(path: @path)
      expect(reloaded.lookup(tools)).to eq("search_catalog" => "findProducts")
    end

    it "writes the file with owner-only permissions" do
      mappings.confirm!(tools, tool_names: { "search_catalog" => "findProducts" })

      expect(File.stat(@path).mode & 0o777).to eq(0o600)
    end
  end

  describe ".load" do
    it "returns an empty store when the file doesn't exist yet" do
      expect(described_class.load(path: @path).to_h).to eq({})
    end

    it "raises on a corrupt file rather than silently falling back" do
      File.write(@path, "not json")

      expect { described_class.load(path: @path) }.to raise_error(JSON::ParserError)
    end
  end
end

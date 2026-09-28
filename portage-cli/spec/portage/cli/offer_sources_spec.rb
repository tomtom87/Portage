require "spec_helper"

RSpec.describe Portage::Cli::OfferSources::ShopifyCatalog do
  let(:mcp_transport) { instance_double(MCP::Client::HTTP) }
  let(:mcp_client) { instance_double(MCP::Client) }

  # Fakes the catalog endpoint at the boundary this codebase already fakes
  # Streamable HTTP at (see portage-ucp-client's http_spec.rb) — WebMock
  # disables real sockets, and the `mcp` gem's own JSON-RPC/SSE framing
  # isn't this class's concern, only what Session#search_catalog hands back.
  def stub_catalog(products)
    allow(MCP::Client::HTTP).to receive(:new).and_return(mcp_transport)
    allow(MCP::Client).to receive(:new).with(transport: mcp_transport).and_return(mcp_client)
    allow(mcp_client).to receive(:connect)
    allow(mcp_client).to receive(:call_tool)
      .and_return({ "result" => { "isError" => false, "content" => [],
                                  "structuredContent" => { "products" => products } } })
  end

  let(:catalog_product) do
    { "id" => "gid://shopify/p/1", "title" => "Trail Boots",
      "price_range" => { "min" => { "amount" => 12_000, "currency" => "GBP" } },
      "variants" => [{ "id" => "gid://shopify/ProductVariant/9", "url" => "https://lemsshoes.com/products/x" }] }
  end

  it "connects straight to the global catalog endpoint, no manifest probe" do
    stub_catalog([catalog_product])

    described_class.new.offers("hiking boots")

    expect(MCP::Client::HTTP).to have_received(:new)
      .with(url: described_class::ENDPOINT, headers: Portage::Cli::UserAgent.headers)
  end

  it "uses the merchant's variant url/id, not the catalog's own product id" do
    stub_catalog([catalog_product])

    offers = described_class.new.offers("hiking boots")

    expect(offers).to eq([{ store: "https://lemsshoes.com", source: "shopify_catalog", checkout: nil,
                            product_id: "gid://shopify/ProductVariant/9", title: "Trail Boots",
                            amount: 12_000, currency: "GBP", url: "https://lemsshoes.com/products/x" }])
  end

  it "drops a product with no variant url to buy from" do
    stub_catalog([{ "id" => "gid://shopify/p/2", "title" => "No URL", "variants" => [{ "id" => "v1" }] }])

    expect(described_class.new.offers("hiking boots")).to be_empty
  end

  it "sends PORTAGE_AGENT_PROFILE, falling back to the repo's published profile when unset" do
    stub_catalog([catalog_product])

    with_env("PORTAGE_AGENT_PROFILE" => nil) do
      described_class.new.offers("hiking boots")
    end

    expect(mcp_client).to have_received(:call_tool) do |**kwargs|
      expect(kwargs[:arguments]["meta"]).to eq("ucp-agent" => { "profile" => Portage::Cli::AgentProfileUrl::DEFAULT })
    end
  end

  it "swallows a connection failure the same way SearchBackends does" do
    allow(Portage::Ucp::Client).to receive(:connect).and_raise(StandardError, "boom")

    expect(described_class.new.offers("hiking boots")).to eq([])
  end

  it "swallows a search_catalog failure" do
    allow(MCP::Client::HTTP).to receive(:new).and_return(mcp_transport)
    allow(MCP::Client).to receive(:new).with(transport: mcp_transport).and_return(mcp_client)
    allow(mcp_client).to receive(:connect)
    allow(mcp_client).to receive(:call_tool).and_raise(StandardError, "boom")

    expect(described_class.new.offers("hiking boots")).to eq([])
  end

  it "times out rather than hanging forever" do
    stub_catalog([catalog_product])
    allow(mcp_client).to receive(:call_tool) { sleep 0.3 }
    stub_const("#{described_class}::TIMEOUT", 0.05)

    expect(described_class.new.offers("hiking boots")).to eq([])
  end
end

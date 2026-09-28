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

# Phase 7 (docs/plans/buy-skill-and-local-browser.md): five official
# retailer buyer-side APIs, each opt-in on its own key, each ending in
# hand-off. Every spec below stubs the real HTTP boundary (WebMock) rather
# than the class's own private methods, same posture as
# SearchBackends::Brave/GoogleCse's specs.
RSpec.describe Portage::Cli::OfferSources do
  describe ".default" do
    it "is just ShopifyCatalog with no retailer keys set" do
      with_env("WALMART_AFFILIATE_API_KEY" => nil, "EBAY_BROWSE_ACCESS_TOKEN" => nil, "BESTBUY_API_KEY" => nil,
               "ETSY_LISTINGS_API_KEY" => nil, "AMAZON_CREATORS_ACCESS_TOKEN" => nil) do
        expect(described_class.default.map(&:name)).to eq(["shopify_catalog"])
      end
    end

    it "adds only the retailers whose key is actually set" do
      with_env("WALMART_AFFILIATE_API_KEY" => "k", "EBAY_BROWSE_ACCESS_TOKEN" => nil, "BESTBUY_API_KEY" => nil,
               "ETSY_LISTINGS_API_KEY" => nil, "AMAZON_CREATORS_ACCESS_TOKEN" => nil) do
        expect(described_class.default.map(&:name)).to eq(%w[shopify_catalog walmart_affiliate])
      end
    end
  end

  describe ".retail_handoff_host?" do
    it "is true for walmart/ebay/bestbuy, and their subdomains" do
      expect(described_class.retail_handoff_host?("www.walmart.com")).to be true
      expect(described_class.retail_handoff_host?("m.ebay.com")).to be true
      expect(described_class.retail_handoff_host?("api.bestbuy.com")).to be true
    end

    it "is false for etsy.com — Buy decides that one itself against the seller adapter's own env" do
      expect(described_class.retail_handoff_host?("www.etsy.com")).to be false
    end

    it "is false for an unrelated host" do
      expect(described_class.retail_handoff_host?("shop.example")).to be false
    end
  end
end

RSpec.describe Portage::Cli::OfferSources::WalmartAffiliate do
  it "is unavailable without a key" do
    expect(described_class.new(api_key: nil).available?).to be false
  end

  it "turns items into offers on walmart.com, never a checkout" do
    item = { "itemId" => 123, "name" => "Kettle", "salePrice" => 19.99,
             "productUrl" => "https://www.walmart.com/ip/kettle/123" }
    stub_request(:get, /api\.walmartlabs\.com/).with(query: hash_including("apiKey" => "k1", "query" => "kettle"))
                                               .to_return(body: { "items" => [item] }.to_json, status: 200)

    offers = described_class.new(api_key: "k1").offers("kettle")

    expect(offers).to eq([{ store: "https://www.walmart.com", source: "walmart_affiliate", checkout: false,
                            product_id: "123", title: "Kettle", amount: 1999, currency: "USD",
                            url: "https://www.walmart.com/ip/kettle/123" }])
  end

  it "drops an item with no product URL" do
    stub_request(:get, /api\.walmartlabs\.com/).to_return(body: { "items" => [{ "itemId" => 1 }] }.to_json,
                                                          status: 200)

    expect(described_class.new(api_key: "k1").offers("kettle")).to eq([])
  end

  it "swallows a non-2xx/timeout the same way every other source does" do
    stub_request(:get, /api\.walmartlabs\.com/).to_return(status: 500)

    expect(described_class.new(api_key: "k1").offers("kettle")).to eq([])
  end
end

RSpec.describe Portage::Cli::OfferSources::EbayBrowse do
  it "needs an access token" do
    expect(described_class.new(access_token: nil).available?).to be false
  end

  it "sends the Buy It Now filter and a bearer token" do
    stub = stub_request(:get, %r{api\.ebay\.com/buy/browse/v1/item_summary/search})
           .with(query: hash_including("filter" => "buyingOptions:{FIXED_PRICE}"),
                 headers: { "Authorization" => "Bearer tok" })
           .to_return(body: { "itemSummaries" => [] }.to_json, status: 200)

    described_class.new(access_token: "tok").offers("kettle")

    expect(stub).to have_been_requested
  end

  it "turns a fixed-price item into an offer on its own item origin" do
    stub_request(:get, /api\.ebay\.com/).to_return(
      body: { "itemSummaries" => [{ "itemId" => "v1|1", "title" => "Kettle", "itemWebUrl" => "https://www.ebay.com/itm/1",
                                    "price" => { "value" => "19.99", "currency" => "USD" },
                                    "buyingOptions" => ["FIXED_PRICE"] }] }.to_json,
      status: 200
    )

    offers = described_class.new(access_token: "tok").offers("kettle")

    expect(offers).to eq([{ store: "https://www.ebay.com", source: "ebay_browse", checkout: false,
                            product_id: "v1|1", title: "Kettle", amount: 1999, currency: "USD",
                            url: "https://www.ebay.com/itm/1" }])
  end

  it "drops an item that isn't Buy It Now even if the API sent one back anyway" do
    stub_request(:get, /api\.ebay\.com/).to_return(
      body: { "itemSummaries" => [{ "itemId" => "v1|1", "itemWebUrl" => "https://www.ebay.com/itm/1",
                                    "buyingOptions" => ["AUCTION"] }] }.to_json,
      status: 200
    )

    expect(described_class.new(access_token: "tok").offers("kettle")).to eq([])
  end
end

RSpec.describe Portage::Cli::OfferSources::BestBuyProducts do
  it "needs a key" do
    expect(described_class.new(api_key: nil).available?).to be false
  end

  it "builds the search(term) query shape and reads products back" do
    stub = stub_request(:get, %r{api\.bestbuy\.com/v1/products\(search=kettle\)})
           .with(query: hash_including("apiKey" => "k1"))
           .to_return(body: { "products" => [{ "sku" => 42, "name" => "Kettle", "salePrice" => 29.99,
                                               "url" => "https://www.bestbuy.com/site/1.p" }] }.to_json,
                      status: 200)

    offers = described_class.new(api_key: "k1").offers("kettle")

    expect(stub).to have_been_requested
    expect(offers).to eq([{ store: "https://www.bestbuy.com", source: "bestbuy_products", checkout: false,
                            product_id: "42", title: "Kettle", amount: 2999, currency: "USD",
                            url: "https://www.bestbuy.com/site/1.p" }])
  end
end

RSpec.describe Portage::Cli::OfferSources::EtsyListings do
  it "needs a key" do
    expect(described_class.new(api_key: nil).available?).to be false
  end

  it "sends x-api-key, never OAuth, for the public buyer-side search" do
    stub = stub_request(:get, %r{openapi\.etsy\.com/v3/application/listings/active})
           .with(headers: { "x-api-key" => "k1" })
           .to_return(body: { "results" => [] }.to_json, status: 200)

    described_class.new(api_key: "k1").offers("kettle")

    expect(stub).to have_been_requested
  end

  it "reads the Money resource's minor units directly, no conversion" do
    stub_request(:get, /openapi\.etsy\.com/).to_return(
      body: { "results" => [{ "listing_id" => 987, "title" => "Kettle",
                              "price" => { "amount" => 1999, "divisor" => 100, "currency_code" => "USD" },
                              "url" => "https://www.etsy.com/listing/987/kettle" }] }.to_json,
      status: 200
    )

    offers = described_class.new(api_key: "k1").offers("kettle")

    expect(offers).to eq([{ store: "https://www.etsy.com", source: "etsy_listings", checkout: false,
                            product_id: "987", title: "Kettle", amount: 1999, currency: "USD",
                            url: "https://www.etsy.com/listing/987/kettle" }])
  end

  it "builds a listing URL from the id when the API doesn't send one" do
    stub_request(:get, /openapi\.etsy\.com/).to_return(
      body: { "results" => [{ "listing_id" => 987, "title" => "Kettle",
                              "price" => { "amount" => 1999, "currency_code" => "USD" } }] }.to_json,
      status: 200
    )

    expect(described_class.new(api_key: "k1").offers("kettle").first[:url]).to eq("https://www.etsy.com/listing/987")
  end
end

RSpec.describe Portage::Cli::OfferSources::AmazonCreators do
  it "needs an access token" do
    expect(described_class.new(access_token: nil).available?).to be false
  end

  it "builds an offer from the PA-API-shaped item resource" do
    listing = { "price" => { "amount" => 19.99, "currency" => "USD" } }
    item = { "asin" => "B000123", "title" => "Kettle", "detailPageUrl" => "https://www.amazon.com/dp/B000123",
             "offers" => { "listings" => [listing] } }
    stub_request(:get, /creators-api\.amazon\.com/).with(headers: { "Authorization" => "Bearer tok" })
                                                   .to_return(body: { "items" => [item] }.to_json, status: 200)

    offers = described_class.new(access_token: "tok").offers("kettle")

    expect(offers).to eq([{ store: "https://www.amazon.com", source: "amazon_creators", checkout: false,
                            product_id: "B000123", title: "Kettle", amount: 1999, currency: "USD",
                            url: "https://www.amazon.com/dp/B000123" }])
  end

  it "drops an item with no ASIN or detail page URL rather than guessing" do
    stub_request(:get, /creators-api\.amazon\.com/).to_return(body: { "items" => [{ "title" => "No id" }] }.to_json,
                                                              status: 200)

    expect(described_class.new(access_token: "tok").offers("kettle")).to eq([])
  end

  it "an Amazon offer still routes to the existing Tier C hand-off path at buy time" do
    expect(Portage::Cli::HandoffOnly.amazon?("www.amazon.com")).to be true
  end
end

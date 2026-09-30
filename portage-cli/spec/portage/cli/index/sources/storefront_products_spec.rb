require "spec_helper"
require "json"
require "tmpdir"

RSpec.describe Portage::Cli::Index::Sources::StorefrontProducts do
  around do |example|
    Dir.mktmpdir do |dir|
      @stores_path = File.join(dir, "stores.json")
      example.run
    end
  end

  let(:origin) { "https://shop.example" }
  let(:stores) { Portage::Cli::Index::Store.new(path: @stores_path) }
  let(:handoff_only) { instance_double(Portage::Cli::HandoffOnly, host?: false) }
  let(:slept) { [] }
  let(:now) { Time.at(1_800_000_000) }

  def source(**opts)
    described_class.new(stores: stores, handoff_only: handoff_only, sleeper: ->(s) { slept << s }, now: now,
                        per_page: 2, **opts)
  end

  def raw(id)
    { "id" => id, "title" => "Lamp #{id}", "handle" => "lamp-#{id}", "vendor" => "Yard", "product_type" => "Lamp",
      "tags" => [], "images" => [], "options" => [],
      "variants" => [{ "id" => id * 10, "title" => "Default Title", "option1" => "Default Title", "sku" => "",
                       "price" => "10.00", "available" => true }] }
  end

  def stub_robots(body = "", status: 200)
    stub_request(:get, "#{origin}/robots.txt").to_return(status: status, body: body)
  end

  def stub_page(page, ids = nil, **response)
    if response.empty?
      response = { status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("products" => Array(ids).map { |i| raw(i) }) }
    end
    stub_request(:get, "#{origin}/products.json").with(query: page_query(page)).to_return(response)
  end

  # Page 1 is requested without `page=`.
  def page_query(page) = page == 1 ? { "limit" => "2" } : { "limit" => "2", "page" => page.to_s }

  def crawl_note(sightings) = sightings.last[:store_fields][:crawl]
  def products_of(sightings) = sightings.select { |s| s[:title] }

  describe "#crawl" do
    it "pages until a short page, waiting between pages, and maps every product" do
      stub_robots
      stub_page(1, [1, 2])
      stub_page(2, [3])

      sightings = source.crawl(origin)

      expect(products_of(sightings).map { |s| s[:title] }).to eq(["Lamp 1", "Lamp 2", "Lamp 3"])
      expect(products_of(sightings).first[:product][:variant_ids]).to eq(["gid://shopify/ProductVariant/10"])
      expect(slept).to eq([described_class::Pages::PAUSE])
      expect(crawl_note(sightings)).to eq("status" => "ok", "reason" => nil, "pages" => 2, "products" => 3,
                                          "at" => now.to_i)
      expect(sightings.last[:store_fields][:platform]).to eq("shopify")
    end

    it "stops at an empty page after a full one" do
      stub_robots
      stub_page(1, [1, 2])
      stub_page(2, [])

      expect(crawl_note(source.crawl(origin))).to include("status" => "ok", "pages" => 2, "products" => 2)
    end

    it "stops at the page cap and says so" do
      stub_robots
      stub_page(1, [1, 2])
      stub_page(2, [3, 4])

      sightings = source(max_pages: 2).crawl(origin)

      expect(products_of(sightings).length).to eq(4)
      expect(crawl_note(sightings)).to include("status" => "partial", "reason" => "page_cap", "pages" => 2)
      expect(a_request(:get,
                       "#{origin}/products.json").with(query: hash_including("page" => "3"))).not_to have_been_made
    end

    it "waits out Retry-After on a first 429, then carries on" do
      stub_robots
      stub_request(:get, "#{origin}/products.json").with(query: page_query(1))
                                                   .to_return({ status: 429, headers: { "Retry-After" => "7" } },
                                                              { status: 200,
                                                                body: JSON.generate("products" => [raw(1)]) })

      sightings = source.crawl(origin)

      expect(slept).to eq([7])
      expect(crawl_note(sightings)).to include("status" => "ok", "products" => 1)
    end

    it "caps a huge Retry-After" do
      stub_robots
      stub_request(:get, "#{origin}/products.json").with(query: page_query(1))
                                                   .to_return({ status: 429, headers: { "Retry-After" => "86400" } },
                                                              { status: 200, body: JSON.generate("products" => []) })

      source.crawl(origin)

      expect(slept).to eq([described_class::Pages::MAX_RETRY_AFTER])
    end

    it "stops the store on a second 429, keeping what it already had" do
      stub_robots
      stub_page(1, [1, 2])
      stub_page(2, status: 429, headers: { "Retry-After" => "1" })

      sightings = source.crawl(origin)

      expect(products_of(sightings).length).to eq(2)
      expect(crawl_note(sightings)).to include("status" => "partial", "reason" => "rate_limited")
      expect(a_request(:get,
                       "#{origin}/products.json").with(query: hash_including("page" => "2"))).to have_been_made.twice
    end

    it "sends no products.json request when robots.txt disallows it" do
      stub_robots("User-agent: *\nDisallow: /products.json\n")

      sightings = source.crawl(origin)

      expect(products_of(sightings)).to eq([])
      expect(crawl_note(sightings)).to include("status" => "skipped", "reason" => "robots")
      expect(a_request(:get, %r{/products\.json})).not_to have_been_made
    end

    it "stays out when robots.txt answers 5xx" do
      stub_robots("", status: 503)

      expect(crawl_note(source.crawl(origin))).to include("status" => "skipped", "reason" => "robots_unreachable")
      expect(a_request(:get, %r{/products\.json})).not_to have_been_made
    end

    it "checks robots.txt against every page URL, stopping where a page is disallowed" do
      stub_robots("User-agent: *\nDisallow: /*page=2\n")
      stub_page(1, [1, 2])

      sightings = source.crawl(origin)

      expect(products_of(sightings).length).to eq(2)
      expect(crawl_note(sightings)).to include("status" => "partial", "reason" => "robots", "pages" => 1)
      expect(a_request(:get, "#{origin}/products.json").with(query: page_query(2))).not_to have_been_made
    end

    it "requests page 1 without page=, so a rule against duplicate ?page=1 URLs doesn't block the catalogue" do
      stub_robots("User-agent: *\nDisallow: *page=1$\n")
      stub_page(1, [1])

      expect(crawl_note(source.crawl(origin))).to include("status" => "ok", "products" => 1)
    end

    it "treats a missing robots.txt as allowed" do
      stub_robots("Not Found", status: 404)
      stub_page(1, [1])

      expect(crawl_note(source.crawl(origin))).to include("status" => "ok")
    end

    {
      "a 404" => [{ status: 404, body: "Not Found" }, "not_found"],
      "an HTML bot wall" => [{ status: 200, headers: { "Content-Type" => "text/html" },
                               body: "<html>Checking your browser</html>" }, "not_json"],
      "an empty body" => [{ status: 200, body: "" }, "not_json"],
      "JSON with no products key" => [{ status: 200, body: "{\"errors\":\"nope\"}" }, "not_json"],
      "an empty first page" => [{ status: 200, body: "{\"products\":[]}" }, "empty"],
      "a 503" => [{ status: 503, body: "" }, "http_503"],
      "a redirect" => [{ status: 301, headers: { "Location" => "https://other.example/products.json" } }, "redirect"]
    }.each do |label, (response, reason)|
      it "skips the store on #{label} and notes why" do
        stub_robots
        stub_page(1, **response)

        sightings = source.crawl(origin)

        expect(products_of(sightings)).to eq([])
        expect(crawl_note(sightings)).to include("status" => "skipped", "reason" => reason, "products" => 0)
        expect(sightings.last[:store_fields]).not_to have_key(:platform)
      end
    end

    it "skips on a network error rather than raising" do
      stub_robots
      stub_request(:get, "#{origin}/products.json").with(query: hash_including({})).to_timeout

      expect(crawl_note(source.crawl(origin))).to include("status" => "skipped",
                                                          "reason" => a_string_starting_with("error"))
    end

    it "never sends a request to a hand-off-only host" do
      allow(handoff_only).to receive(:host?).with("shop.example").and_return(true)

      sightings = source.crawl(origin)

      expect(crawl_note(sightings)).to include("status" => "skipped", "reason" => "handoff_only")
      expect(a_request(:any, /shop\.example/)).not_to have_been_made
    end

    it "names itself with the shared User-Agent" do
      stub_robots
      stub_page(1, [1])

      source.crawl(origin)

      expect(a_request(:get, "#{origin}/products.json").with(query: hash_including({}),
                                                             headers: Portage::Cli::UserAgent.headers))
        .to have_been_made
    end

    it "asks for robots.txt as text and products.json as JSON" do
      stub_robots
      stub_page(1, [1])

      source.crawl(origin)

      expect(a_request(:get, "#{origin}/robots.txt").with(headers: { "Accept" => "text/plain" })).to have_been_made
      expect(a_request(:get, "#{origin}/products.json").with(query: hash_including({}),
                                                             headers: { "Accept" => "application/json" }))
        .to have_been_made
    end

    it "skips a store on a platform it has no endpoint for, with no request" do
      sightings = source.crawl(origin, platform: "woocommerce")

      expect(crawl_note(sightings)).to include("status" => "skipped", "reason" => "unsupported_platform")
      expect(a_request(:any, /shop\.example/)).not_to have_been_made
    end
  end

  describe ".endpoint_for" do
    it "is products.json for Shopify or an unknown platform, nil otherwise" do
      expect(described_class.endpoint_for(origin, "shopify")).to eq("#{origin}/products.json")
      expect(described_class.endpoint_for(origin, nil)).to eq("#{origin}/products.json")
      expect(described_class.endpoint_for(origin, "woocommerce")).to be_nil
    end
  end

  describe "#candidates" do
    it "crawls the index's own origins, least recently crawled first, up to the store cap" do
      stores.upsert("https://a.example", platform: "shopify", crawl: { "at" => 50 })
      stores.upsert("https://b.example", platform: nil)
      stores.upsert("https://c.example", platform: "shopify", crawl: { "at" => 10 })
      stores.upsert("https://woo.example", platform: "woocommerce")
      crawled = []
      src = source(max_stores: 2)
      allow(src).to receive(:crawl) { |o, **| crawled << o and [] }

      src.candidates

      expect(crawled).to eq(%w[https://b.example https://c.example])
    end

    it "never crawls a hand-off-only origin in the index" do
      stores.upsert("https://www.amazon.co.uk", platform: nil)
      allow(handoff_only).to receive(:host?).with("www.amazon.co.uk").and_return(true)

      expect(source.candidates).to eq([])
      expect(a_request(:any, /amazon/)).not_to have_been_made
    end

    it "accepts and ignores the shared queries: keyword" do
      expect(source.candidates(queries: ["x"])).to eq([])
    end
  end

  it "is registered, off by default" do
    expect(Portage::Cli::Index::Sources.build("storefront_products")).to be_a(described_class)
    expect(Portage::Cli::Index::Sources::DEFAULT_NAMES).not_to include("storefront_products")
  end
end

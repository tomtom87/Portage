require "spec_helper"

RSpec.describe Portage::Cli::Check do
  let(:store) { "https://shop.example" }
  let(:manifest) { { "ucp" => { "version" => "2026-01-11" } } }
  let(:shopify_tools) do
    %w[search_catalog browse_store get_product show_variant add_to_cart get_cart update_cart_lines cancel_cart
       proceed_to_checkout manage_orders search_shop_policies_and_faqs].map { |name| { "name" => name } }
  end
  let(:bridge_class) do
    Class.new do
      def initialize(tools) = @tools = tools
      attr_reader :tools

      def list_tools = @tools
    end
  end

  # No real browser profile is ever looked for: with no bridge injected the
  # check would probe 127.0.0.1's debugging port.
  before do
    allow(Portage::Cli::BrowserProfile::Profile).to receive(:new)
      .and_return(instance_double(Portage::Cli::BrowserProfile::Profile, status: { running: false }, port: 9223))
  end

  def stub_manifest(status: 404, body: "")
    stub_request(:get, "#{store}/.well-known/ucp").to_return(status: status, body: body)
  end

  def stub_homepage(body)
    stub_request(:get, "#{store}/").to_return(status: 200, body: body)
  end

  def clean_env(&) = with_env(Portage::Ucp::Resolver::PLATFORMS.flat_map { |p| p.env.values }.to_h { |v| [v, nil] }, &)

  it "reports native UCP as automated" do
    stub_manifest(status: 200, body: JSON.generate(manifest))

    report = described_class.call(store)

    expect(report).to include(url: store, native_ucp: manifest, verdict: "automated", handoff_only: false)
    expect(report[:next_step]).to match(/speaks UCP natively/)
    expect(report[:index_hint]).to eq("portage index add #{store} --crawl")
    expect(report[:webmcp][:status]).to eq("skipped")
  end

  it "defaults the scheme to https" do
    stub_manifest(status: 200, body: JSON.generate(manifest))

    expect(described_class.call("shop.example")[:url]).to eq(store)
  end

  it "lists the missing env vars for a detected WooCommerce store as a hand-off" do
    stub_manifest
    stub_homepage('<link href="/wp-content/plugins/woocommerce/x.css">')

    report = clean_env { described_class.call(store) }

    expect(report[:verdict]).to eq("handoff")
    expect(report[:platform]).to eq("WooCommerce")
    expect(report[:adapter]).to include(gem: "portage-ucp-woocommerce",
                                        missing_env: %w[WOOCOMMERCE_SITE_URL WOOCOMMERCE_CONSUMER_KEY
                                                        WOOCOMMERCE_CONSUMER_SECRET])
    expect(report[:next_step]).to include("WOOCOMMERCE_SITE_URL").and include("Portage opens the store")
  end

  it "flags a Shopify store as a hand-off with its adapter details" do
    stub_manifest
    stub_homepage('<script src="https://cdn.shopify.com/s/x.js"></script>')

    report = clean_env { described_class.call(store) }

    expect(report).to include(platform: "Shopify", verdict: "handoff")
    expect(report[:adapter]).to include(gem: "portage-ucp-shopify", missing_env: ["SHOPIFY_SHOP_DOMAIN"])
    expect(report[:adapter]).to have_key(:installed)
  end

  # docs/plans/local-catalogue.md Phase 2: check never crawls, it only
  # names the command that would.
  it "suggests crawling a Shopify or native-UCP store into the local index, and never does it itself" do
    stub_manifest
    stub_homepage('<script src="https://cdn.shopify.com/s/x.js"></script>')

    report = clean_env { described_class.call(store) }

    expect(report[:index_hint]).to eq("portage index add #{store} --crawl")
    expect(a_request(:get, %r{/products\.json})).not_to have_been_made
  end

  it "gives no index hint for a store it can't crawl" do
    stub_manifest
    stub_homepage('<link href="/wp-content/plugins/woocommerce/x.css">')

    expect(clean_env { described_class.call(store) }).not_to have_key(:index_hint)
  end

  it "makes no HTTP request for a hand-off-only host" do
    report = described_class.call("https://www.amazon.com/dp/B000")

    expect(report).to include(handoff_only: true, verdict: "handoff", adapter: nil, native_ucp: nil)
    expect(report).not_to have_key(:index_hint)
    expect(report[:webmcp][:status]).to eq("skipped")
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "honours the user's own hand-off-only list and the built-in retailers" do
    handoff_only = Portage::Cli::HandoffOnly.new(config: Portage::Cli::Config.load(path: @config_path))
    allow(handoff_only).to receive(:host?).with("shop.example").and_return(true)

    expect(described_class.call(store, handoff_only: handoff_only)[:handoff_only]).to be true
    expect(described_class.call("https://www.walmart.com/ip/1")[:handoff_only]).to be true
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "reports webmcp when the page registers a cart-and-checkout tool set" do
    stub_manifest
    stub_homepage("<html></html>")

    report = described_class.call(store, webmcp_bridge: bridge_class.new(shopify_tools))

    expect(report[:webmcp]).to include(status: "available")
    expect(report[:webmcp][:tools]).to include("add_to_cart", "proceed_to_checkout")
    expect(report).to include(verdict: "webmcp")
    expect(report[:next_step]).to match(/build the cart; you pay in your browser/)
  end

  it "prefers webmcp over a detected platform whose adapter isn't usable, as buy does" do
    stub_manifest
    stub_homepage('<script src="https://cdn.shopify.com/s/x.js"></script>')

    report = clean_env { described_class.call(store, webmcp_bridge: bridge_class.new(shopify_tools)) }

    expect(report).to include(verdict: "webmcp", platform: "Shopify")
  end

  it "reports none when the page's tools aren't a cart and checkout" do
    stub_manifest
    stub_homepage("<html></html>")

    report = described_class.call(store, webmcp_bridge: bridge_class.new([{ "name" => "say_hello" }]))

    expect(report[:webmcp]).to include(status: "none", tools: ["say_hello"])
    expect(report[:verdict]).to eq("unsupported")
  end

  it "reports an error when reading the page's tools fails" do
    stub_manifest
    stub_homepage("<html></html>")
    bridge = bridge_class.new([])
    allow(bridge).to receive(:list_tools).and_raise(Portage::Ucp::WebMcp::BridgeError, "boom")

    report = described_class.call(store, webmcp_bridge: bridge)

    expect(report[:webmcp]).to include(status: "error")
    expect(report[:webmcp][:reason]).to include("boom")
    expect(report[:verdict]).to eq("unsupported")
  end

  it "is unsupported, with WebMCP skipped, when nothing is found and no browser is attached" do
    stub_manifest
    stub_homepage("<html>a plain page</html>")

    report = described_class.call(store)

    expect(report).to include(verdict: "unsupported", platform: nil, adapter: nil)
    expect(report[:webmcp][:status]).to eq("skipped")
    expect(report[:webmcp][:reason]).to match(/never launches a browser/)
  end

  it "skips WebMCP when portage-ucp-webmcp isn't installed" do
    allow(Portage::Cli::Webmcp).to receive(:available?).and_return(false)
    stub_manifest
    stub_homepage("<html></html>")

    expect(described_class.call(store)[:webmcp]).to include(status: "skipped",
                                                            reason: "portage-ucp-webmcp isn't installed")
  end

  it "reports automated when a detected adapter answers a live probe" do
    checker = lambda { |_url|
      { url: "#{store}/", native_ucp: nil, platform: "Shopify", recommended_gem: "portage-ucp-shopify",
        live_probe: { status: "ok", sample_product: nil } }
    }

    report = described_class.call(store, checker: checker)

    expect(report[:verdict]).to eq("automated")
    expect(report[:next_step]).to include("portage-ucp-shopify")
  end
end

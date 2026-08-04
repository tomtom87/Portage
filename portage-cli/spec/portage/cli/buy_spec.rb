require "spec_helper"

RSpec.describe Portage::Cli::Buy do
  let(:product) { { "id" => "p1", "title" => "Cold Brew" } }
  let(:incomplete_checkout) { { "id" => "chk_1", "status" => "ready_for_complete", "links" => [], "totals" => [] } }
  let(:completed_checkout) { { "id" => "chk_1", "status" => "completed", "links" => [], "totals" => [] } }

  def fake_session(advertises_checkout:, checkout: nil, completed: nil)
    instance_double(
      Portage::Ucp::Client::Session,
      advertises?: advertises_checkout,
      search_catalog: [product],
      create_checkout: checkout,
      complete_checkout: completed
    )
  end

  describe "native UCP, cart+checkout advertised" do
    it "creates a checkout and reports it awaiting confirmation without --yes" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example").and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("native_ucp")
      expect(report[:checkout]).to be true
      expect(report[:message]).to include("--yes")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "completes the purchase when --yes and --payment-token are given" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to eq("Purchased.")
      expect(report[:checkout_status]).to eq("completed")
      expect(session).to have_received(:complete_checkout).with(checkout_id: "chk_1", payment_token: "tok_1")
    end

    it "stops after create_checkout on --dry-run without completing" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, dry_run: true).call

      expect(report[:message]).to include("Dry run")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "reports a purchase can't complete without a payment token even with --yes" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:message]).to include("--payment-token")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "surfaces requires_escalation as data, not an error, with the checkout_url" do
      escalation = { "id" => "chk_1", "status" => "requires_escalation",
                     "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }],
                     "totals" => [] }
      session = fake_session(advertises_checkout: true, checkout: escalation)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to include("requires buyer escalation")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "reports no match without touching checkout when the catalog search is empty" do
      session = fake_session(advertises_checkout: true)
      allow(session).to receive(:search_catalog).and_return([])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "nonexistent").call

      expect(report[:message]).to include("No product matched")
      expect(session).not_to have_received(:create_checkout)
    end
  end

  describe "native UCP, catalog only" do
    before do
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html>nothing recognizable</html>")
    end

    it "browses via the manifest and reports checkout isn't available when no adapter matches" do
      session = fake_session(advertises_checkout: false)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Ucp::Resolver).to receive(:detect_platform).and_return(nil)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("native_ucp")
      expect(report[:browse]).to be true
      expect(report[:checkout]).to be false
      expect(report[:message]).to include("can't check out via UCP yet")
    end
  end

  describe "no native manifest — homepage fallback" do
    it "follows an alternate <link rel=\"ucp\"> manifest pointer" do
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example").and_return(nil)
      stub_request(:get, "https://shop.example/").to_return(
        status: 200, body: '<html><head><link rel="ucp" href="https://ucp.shop.example/manifest"></head></html>'
      )
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://ucp.shop.example/manifest").and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("native_ucp")
    end

    it "detects a platform and reports a dead end when required env vars are missing" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("none")
      expect(report[:message]).to include("visit")
    end

    it "reports a dead end when nothing recognizable is found at all" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html>hello</html>")

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("none")
      expect(report[:browse]).to be false
      expect(report[:checkout]).to be false
    end

    it "runs a full buy via the loopback transport when a matching adapter can check out" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

      platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Shopify" }
      allow(Portage::Ucp::Resolver).to receive(:detect_platform).and_return(platform)
      allow(Portage::Ucp::Resolver).to receive(:env_for).and_return({ shop_domain: "shop.example" })
      allow(Portage::Ucp::Resolver).to receive(:missing_env).and_return([])
      adapter = double("adapter")
      allow(Portage::Ucp::Resolver).to receive(:build_adapter).and_return(adapter)
      allow(Portage::Ucp::Capabilities::CART).to receive(:advertised_for?).with(adapter).and_return(true)
      allow(Portage::Ucp::Capabilities::CHECKOUT).to receive(:advertised_for?).with(adapter).and_return(true)

      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:for_adapter).with(adapter, anything).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("adapter:Shopify")
      expect(report[:checkout]).to be true
    end
  end
end

require "spec_helper"

RSpec.describe Portage::Cli::Buy do
  # Never let #complete's `@payment_token ||= PaymentMethods.default`
  # fallback hit the real Keychain/secret-tool/env — nil here means "as if
  # nothing were enrolled", same as before Phase 1 existed. Tests that care
  # about the fallback override this explicitly.
  before { allow(Portage::Cli::PaymentMethods).to receive(:default).and_return(nil) }

  let(:product) { { "id" => "p1", "title" => "Cold Brew" } }
  let(:incomplete_checkout) { { "id" => "chk_1", "status" => "ready_for_complete", "links" => [], "totals" => [] } }
  let(:completed_checkout) { { "id" => "chk_1", "status" => "completed", "links" => [], "totals" => [] } }

  def fake_session(advertises_checkout:, checkout: nil, completed: nil)
    instance_double(
      Portage::Ucp::Client::Session,
      advertises?: advertises_checkout,
      search_catalog: { "ucp" => 1, "products" => [product] },
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

    it "checks out the product's first variant id, not the product id, when the product has variants" do
      variant_product = { "id" => "p1", "title" => "Cold Brew",
                          "variants" => [{ "id" => "v1" }, { "id" => "v2" }] }
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [variant_product] },
                                       create_checkout: incomplete_checkout
      )
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      described_class.new(url: "shop.example", query: "cold").call

      expect(session).to have_received(:create_checkout) do |**kwargs|
        expect(kwargs[:line_items]).to eq([{ product_id: "v1", quantity: 1 }])
      end
    end

    it "stops after create_checkout on --dry-run without completing" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, dry_run: true).call

      expect(report[:message]).to include("Dry run")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "reports no payment token even with --yes, with the checkout_url as a fallback" do
      checkout = incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      )
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:message]).to include("--payment-token")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "falls back to the stored default payment method when --payment-token is omitted" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::PaymentMethods).to receive(:default).and_return("tok_default")

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:message]).to eq("Purchased.")
      expect(session).to have_received(:complete_checkout).with(checkout_id: "chk_1", payment_token: "tok_default")
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
      expect(report[:handoff]).to eq(url: "https://shop.example/checkout/chk_1", opened: false,
                                     notified: false, notify_error: nil)
      expect(session).not_to have_received(:complete_checkout)
    end

    it "reports a permission-denied completion as a normal outcome, via continue_url" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      ))
      allow(session).to receive(:complete_checkout)
        .and_raise(Portage::Ucp::Client::PaymentPermissionError, "no checkout-completion grant")
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to include("isn't yet granted permission")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(report[:checkout_status]).to eq("ready_for_complete")
      expect(report[:handoff]).to eq(url: "https://shop.example/checkout/chk_1", opened: false,
                                     notified: false, notify_error: nil)
    end

    it "auto-opens the checkout_url on a dead end when --auto-open is given" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      ))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow_any_instance_of(Portage::Cli::CheckoutHandoff).to receive(:system).and_return(true)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, auto_open: true).call

      expect(report[:handoff]).to include(url: "https://shop.example/checkout/chk_1", opened: true)
    end

    it "posts to the configured webhook on a dead end and reports notified: true" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      ))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      stub = stub_request(:post, "https://hooks.example/x")
             .with(body: hash_including("event" => "checkout_handoff", "reason" => "no_payment_token",
                                        "checkout_url" => "https://shop.example/checkout/chk_1"))
             .to_return(status: 200, body: "{}")

      report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                   notify_webhook: "https://hooks.example/x").call

      expect(report[:handoff]).to include(notified: true, notify_error: nil)
      expect(stub).to have_been_requested
    end

    it "doesn't raise when the webhook POST fails, and surfaces notify_error on the report" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      ))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      stub_request(:post, "https://hooks.example/x").to_return(status: 500, body: "{}")

      report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                   notify_webhook: "https://hooks.example/x").call

      expect(report[:handoff][:notified]).to be false
      expect(report[:handoff][:notify_error]).to include("500")
    end

    it "never attempts a webhook request when no notify webhook is configured" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout.merge(
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      ))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(a_request(:post, /.*/)).not_to have_been_made
    end

    it "never auto-opens on --dry-run even when escalation hits and --auto-open is given" do
      escalation = { "id" => "chk_1", "status" => "requires_escalation",
                     "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }],
                     "totals" => [] }
      session = fake_session(advertises_checkout: true, checkout: escalation)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::CheckoutHandoff).to receive(:new)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, dry_run: true,
                                   auto_open: true).call

      expect(report[:handoff]).to be_nil
      expect(Portage::Cli::CheckoutHandoff).not_to have_received(:new)
    end

    it "unwraps search_catalog's wire envelope instead of treating it as the product list" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example").and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:products]).to eq([product])
    end

    it "reports no match without touching checkout when the catalog search is empty" do
      session = fake_session(advertises_checkout: true)
      allow(session).to receive(:search_catalog).and_return({ "ucp" => 1, "products" => [] })
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

    it "warns (rather than silently swallowing) a manifest this client couldn't parse, then falls through" do
      allow(Portage::Ucp::Client).to receive(:discover)
        .and_raise(Portage::Ucp::Client::ManifestShapeError, "manifest has no mcp service entry to connect to")
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html>hello</html>")

      report = nil
      expect { report = described_class.new(url: "shop.example", query: "cold").call }
        .to output(/shop\.example.*couldn't parse/).to_stderr

      expect(report[:source]).to eq("none")
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
      allow(Portage::Ucp::Capabilities::FULFILLMENT).to receive(:advertised_for?).with(adapter).and_return(false)

      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:for_adapter).with(adapter, anything).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("adapter:Shopify")
      expect(report[:checkout]).to be true
    end

    it "falls through to the generic dead end when the adapter gem isn't installed" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

      platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Shopify" }
      allow(Portage::Ucp::Resolver).to receive_messages(detect_platform: platform,
                                                        env_for: { shop_domain: "shop.example" }, missing_env: [])
      allow(Portage::Ucp::Resolver).to receive(:build_adapter).and_raise(LoadError, "cannot load such file")

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("none")
      expect(report[:message]).to include("visit")
    end

    it "surfaces a live adapter's own error instead of the generic dead end" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

      platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Shopify" }
      allow(Portage::Ucp::Resolver).to receive_messages(detect_platform: platform,
                                                        env_for: { shop_domain: "shop.example" }, missing_env: [])
      adapter = double("adapter")
      allow(Portage::Ucp::Resolver).to receive(:build_adapter).and_return(adapter)
      allow(Portage::Ucp::Capabilities::CART).to receive(:advertised_for?).with(adapter).and_return(true)
      allow(Portage::Ucp::Capabilities::CHECKOUT).to receive(:advertised_for?).with(adapter)
                                                                              .and_raise("no payment_method configured on this Adapter")

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("adapter:Shopify")
      expect(report[:checkout]).to be false
      expect(report[:message]).to include("no payment_method configured on this Adapter")
    end

    it "unwraps a CatalogSearchResult struct from the own-store catalog-only adapter path" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

      platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Shopify" }
      allow(Portage::Ucp::Resolver).to receive_messages(detect_platform: platform,
                                                        env_for: { shop_domain: "shop.example" }, missing_env: [])

      price = Portage::Ucp::Price.new(amount: 500, currency: "USD")
      variant = Portage::Ucp::Variant.new(id: "v1", title: "Default", description: Portage::Ucp::Description.new,
                                          price: price)
      product_struct = Portage::Ucp::Product.new(
        id: "p1", title: "Cold Brew", description: Portage::Ucp::Description.new,
        price_range: Portage::Ucp::PriceRange.new(min: price, max: price), variants: [variant]
      )
      adapter = double("adapter", search_catalog: Portage::Ucp::CatalogSearchResult.new(products: [product_struct]))
      allow(Portage::Ucp::Resolver).to receive(:build_adapter).and_return(adapter)
      allow(Portage::Ucp::Capabilities::CART).to receive(:advertised_for?).with(adapter).and_return(false)
      allow(Portage::Ucp::Capabilities::CHECKOUT).to receive(:advertised_for?).with(adapter).and_return(false)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("adapter:Shopify")
      expect(report[:products]).to eq([product_struct])
    end

    it "submits PORTAGE_SHIP_* as the checkout destination and auto-picks the cheapest option" do
      with_env(
        "PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
        "PORTAGE_SHIP_POSTAL_CODE" => "16501"
      ) do
        allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
        stub_request(:get, "https://shop.example/")
          .to_return(status: 200, body: '<script src="https://cdn.shopify.com/x.js"></script>')

        platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Shopify" }
        allow(Portage::Ucp::Resolver).to receive_messages(detect_platform: platform,
                                                          env_for: { shop_domain: "shop.example" }, missing_env: [])
        adapter = double("adapter")
        allow(Portage::Ucp::Resolver).to receive(:build_adapter).and_return(adapter)
        allow(Portage::Ucp::Capabilities::CART).to receive(:advertised_for?).with(adapter).and_return(true)
        allow(Portage::Ucp::Capabilities::CHECKOUT).to receive(:advertised_for?).with(adapter).and_return(true)
        allow(Portage::Ucp::Capabilities::FULFILLMENT).to receive(:advertised_for?).with(adapter).and_return(true)

        priced_checkout = incomplete_checkout.merge(
          "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }],
          "fulfillment" => { "methods" => [{ "groups" => [
            { "id" => "grp_1", "line_item_ids" => ["li_1"], "selected_option_id" => nil,
              "options" => [{ "id" => "express", "totals" => [{ "amount" => 1500 }] },
                            { "id" => "standard", "totals" => [{ "amount" => 500 }] }] }
          ] }] }
        )
        session = instance_double(
          Portage::Ucp::Client::Session, advertises?: true,
                                         search_catalog: { "ucp" => 1, "products" => [product] },
                                         create_checkout: priced_checkout, update_checkout: completed_checkout
        )
        allow(Portage::Ucp::Client).to receive(:for_adapter).with(adapter, anything).and_return(session)

        described_class.new(url: "shop.example", query: "cold").call

        expect(session).to have_received(:create_checkout) do |**kwargs|
          destination = kwargs[:fulfillment].shipping_methods.first.destinations.first
          expect(destination.address.address_locality).to eq("Erie")
        end
        expect(session).to have_received(:update_checkout) do |**kwargs|
          expect(kwargs[:line_items]).to eq([{ product_id: "p1", quantity: 1 }])
          selected_group = kwargs[:fulfillment].shipping_methods.first.groups.first
          expect(selected_group.selected_option_id).to eq("standard")
        end
      end
    end
  end
end

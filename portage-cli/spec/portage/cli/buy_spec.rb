require "spec_helper"
require "portage/ucp/webmcp"
require "stringio"

RSpec.describe Portage::Cli::Buy do
  # Never let #complete's `@payment_token ||= PaymentMethods.default`
  # fallback hit the real Keychain/secret-tool/env — nil here means "as if
  # nothing were enrolled", same as before Phase 1 existed. Tests that care
  # about the fallback override this explicitly.
  before { allow(Portage::Cli::PaymentMethods).to receive(:default).and_return(nil) }

  # Same idea for the decision layer's gates: never read the real
  # ~/.portage/policy.json, and never pick up a PORTAGE_DECISION_BACKEND
  # from the shell running the suite. Tests that care override these.
  before { allow(Portage::Ucp::Policy).to receive(:load).and_return(Portage::Ucp::Policy.new(data: {})) }
  around { |example| with_env("PORTAGE_DECISION_BACKEND" => nil, "PORTAGE_MIN_CONFIDENCE" => nil) { example.run } }

  let(:product) { { "id" => "p1", "title" => "Cold Brew" } }
  # Holds exactly the requested line, so #reconcile_checkout finds no
  # mismatch — any mismatch now stops a real purchase.
  let(:incomplete_checkout) do
    { "id" => "chk_1", "status" => "ready_for_complete", "links" => [], "totals" => [],
      "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }] }
  end
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

  describe "which URL a dead-end checkout hands the shopper" do
    def report_for(checkout)
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [product] },
                                       create_checkout: checkout
      )
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      described_class.new(url: "shop.example", query: "cold", yes: true).call
    end

    # Regression: `links` on a real store holds only policy links — five
    # third-party Shopify stores checked 2026-09-22 returned refund_policy,
    # privacy_policy, terms_of_service, shipping_policy and
    # contact_information, never a checkout link — so taking the first link
    # with a url handed the shopper a refund policy every time, and
    # --auto-open opened it.
    it "prefers continue_url over the policy links a real store puts in links" do
      checkout = {
        "id" => "chk_1", "status" => "ready_for_complete", "totals" => [],
        "links" => [{ "type" => "refund_policy", "url" => "https://shop.example/policies/refund" },
                    { "type" => "privacy_policy", "url" => "https://shop.example/policies/privacy" }],
        "continue_url" => "https://shop.example/cart/c/abc123"
      }

      expect(report_for(checkout)[:checkout_url]).to eq("https://shop.example/cart/c/abc123")
    end

    it "hands over no URL at all rather than a policy link when continue_url is absent" do
      checkout = {
        "id" => "chk_1", "status" => "ready_for_complete", "totals" => [],
        "links" => [{ "type" => "refund_policy", "url" => "https://shop.example/policies/refund" }]
      }

      expect(report_for(checkout)[:checkout_url]).to be_nil
    end

    it "still falls back to a non-policy link for a backend that puts the checkout there" do
      checkout = {
        "id" => "chk_1", "status" => "ready_for_complete", "totals" => [],
        "links" => [{ "type" => "privacy_policy", "url" => "https://shop.example/policies/privacy" },
                    { "type" => "checkout", "url" => "https://shop.example/checkout/9" }]
      }

      expect(report_for(checkout)[:checkout_url]).to eq("https://shop.example/checkout/9")
    end
  end

  describe "a store refusing the call on its own terms" do
    # Regression: this escaped #call as an unhandled ServerError and printed
    # a Ruby backtrace whose message was the server's whole several-kilobyte
    # error envelope. Confirmed live 2026-09-22 against a genuinely sold-out
    # variant on a Shopify store.
    it "reports the server's own message and continue_url instead of raising" do
      body = JSON.generate(
        "ucp" => { "status" => "error" },
        "messages" => [{ "type" => "error", "code" => "out_of_stock", "content" => "Sold out",
                         "severity" => "unrecoverable" }],
        "continue_url" => "https://shop.example/"
      )
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [product] }
      )
      allow(session).to receive(:create_checkout)
        .and_raise(Portage::Ucp::Client::ServerError.new(body, payload: JSON.parse(body)))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("native_ucp")
      expect(report[:checkout]).to be false
      expect(report[:checkout_url]).to eq("https://shop.example/")
      expect(report[:message]).to include("Sold out").and include("https://shop.example/")
      expect(report[:message]).not_to include("out_of_stock")
    end

    it "falls back to the raw text for a refusal that isn't a JSON document" do
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [product] }
      )
      allow(session).to receive(:create_checkout)
        .and_raise(Portage::Ucp::Client::ServerError, "rate limited")
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:message]).to include("rate limited")
      expect(report[:checkout_url]).to be_nil
    end
  end

  # Regression: the top search hit and its first variant were bought
  # unconditionally, so a sold-out top hit dead-ended on "Sold out" with
  # in-stock matches right below it (allbirds.com, billabong.com, 2026-09-23).
  describe "which product and variant it checks out" do
    def variant(id, available)
      { "id" => id, "availability" => { "available" => available } }
    end

    def checked_out_id(products, **options)
      session = instance_double(Portage::Ucp::Client::Session, advertises?: true,
                                                               search_catalog: { "products" => products },
                                                               create_checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      described_class.new(url: "shop.example", query: "cold", **options).call
      ids = []
      expect(session).to have_received(:create_checkout) { |line_items:, **| ids << line_items.first[:product_id] }
      ids.first
    end

    it "skips a sold-out top hit for the first product with stock" do
      sold_out = { "id" => "p1", "variants" => [variant("v1", false)] }
      in_stock = { "id" => "p2", "variants" => [variant("v2", true)] }

      expect(checked_out_id([sold_out, in_stock])).to eq("v2")
    end

    it "takes the first in-stock variant over a sold-out first variant" do
      product = { "id" => "p1", "variants" => [variant("v1", false), variant("v2", true)] }

      expect(checked_out_id([product])).to eq("v2")
    end

    it "falls back to the top hit when nothing reports stock, so the store still answers" do
      products = [{ "id" => "p1", "variants" => [variant("v1", false)] },
                  { "id" => "p2", "variants" => [variant("v2", false)] }]

      expect(checked_out_id(products)).to eq("v1")
    end

    it "still buys exactly the --product-id asked for, sold out or not" do
      sold_out = { "id" => "p1", "variants" => [variant("v1", false)] }
      in_stock = { "id" => "p2", "variants" => [variant("v2", true)] }

      expect(checked_out_id([in_stock, sold_out], product_id: "p1")).to eq("v1")
    end

    # OfferSources::ShopifyCatalog hands Find an offer whose product_id is
    # the merchant's own variant gid, not the catalog's global product id
    # (see that class) — --product-id then names a variant, and the product
    # carrying it is matched by that variant, not by its own top-level id.
    it "matches and buys the variant OfferSources::ShopifyCatalog named, not just a top-level product id" do
      other = { "id" => "p1", "variants" => [variant("v1", true)] }
      catalog_match = { "id" => "gid://shopify/p/9",
                        "variants" => [variant("gid://shopify/ProductVariant/9", true),
                                       variant("gid://shopify/ProductVariant/10", true)] }

      expect(checked_out_id([other, catalog_match], product_id: "gid://shopify/ProductVariant/9"))
        .to eq("gid://shopify/ProductVariant/9")
    end
  end

  describe "native UCP, cart+checkout advertised" do
    it "creates a checkout and reports it awaiting confirmation without --yes" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example", headers: Portage::Cli::UserAgent.headers).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("native_ucp")
      expect(report[:checkout]).to be true
      expect(report[:outcome]).to eq("needs_confirmation")
      expect(report[:message]).to include("--yes")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "completes the purchase when --yes and --payment-token are given" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to eq("Purchased.")
      expect(report[:outcome]).to eq("purchased")
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
      expect(report[:outcome]).to eq("dry_run")
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
      # Nothing in `decisions` held this one, so only `outcome` tells an
      # agent it isn't a purchase.
      expect(report[:outcome]).to eq("no_payment_token")
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
      expect(report[:outcome]).to eq("requires_escalation")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(report[:handoff]).to eq(url: "https://shop.example/checkout/chk_1", opened: false,
                                     notified: false, notify_error: nil, handoff_target: "default")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "treats requires_escalation from complete_checkout as an escalation, not a purchase" do
      # Regression: this used to report "Purchased." unconditionally,
      # ignoring `completed["status"]` — a Shopify cartSubmitForCompletion
      # result carrying `errors` returns requires_escalation from
      # complete_checkout itself, not just from create_checkout.
      escalation_after_payment = {
        "id" => "chk_1", "status" => "requires_escalation", "totals" => [],
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }]
      }
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout,
                             completed: escalation_after_payment)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to include("requires buyer escalation")
      expect(report[:message]).not_to eq("Purchased.")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
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
      expect(report[:outcome]).to eq("permission_denied")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(report[:checkout_status]).to eq("ready_for_complete")
      expect(report[:handoff]).to eq(url: "https://shop.example/checkout/chk_1", opened: false,
                                     notified: false, notify_error: nil, handoff_target: "default")
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
                                        "checkout_url" => "https://shop.example/checkout/chk_1",
                                        "store" => "https://shop.example", "query" => "cold",
                                        "message" => a_string_including("--payment-token")))
             .to_return(status: 200, body: "ok") # Slack's plain-text reply

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
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example", headers: Portage::Cli::UserAgent.headers).and_return(session)

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

  describe "a quote's cap (buy --quote)" do
    def priced(amount, currency: "USD")
      incomplete_checkout.merge("currency" => currency, "totals" => [{ "type" => "total", "amount" => amount }],
                                "continue_url" => "https://shop.example/cart/c/1")
    end

    def buy_against(checkout, **overrides)
      session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1",
                                   quote_total: 2400, quote_currency: "USD", **overrides).call
      [report, session]
    end

    it "refuses with quote_changed, both totals, no hand-off and no charge, when the total went up" do
      report, session = buy_against(priced(2500))

      expect(report).to include(outcome: "quote_changed", quoted_total: 2400, quoted_currency: "USD",
                                current_total: 2500, current_currency: "USD", handoff: nil)
      expect(report[:message]).to include("24.00 USD", "25.00 USD")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "refuses when the currency differs or the total is missing" do
      changed_currency, = buy_against(priced(2400, currency: "GBP"))
      unpriced, = buy_against(priced(2400).merge("totals" => []))

      expect([changed_currency[:outcome], unpriced[:outcome]]).to eq(%w[quote_changed quote_changed])
      expect(unpriced[:current_total]).to be_nil
      expect(unpriced[:message]).to include("was 24.00 USD, now unknown")
    end

    it "does not hand off a checkout that needs escalation once the price has gone up" do
      report, = buy_against(priced(2500).merge("status" => "requires_escalation"))

      expect(report).to include(outcome: "quote_changed", handoff: nil)
    end

    it "buys at the quoted total" do
      report, session = buy_against(priced(2400))

      expect(report[:outcome]).to eq("purchased")
      expect(session).to have_received(:complete_checkout)
    end

    it "buys at a lower total" do
      report, session = buy_against(priced(2000))

      expect(report[:outcome]).to eq("purchased")
      expect(session).to have_received(:complete_checkout)
    end

    it "sets no cap without a quote" do
      session = fake_session(advertises_checkout: true, checkout: priced(999_999), completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:outcome]).to eq("purchased")
    end
  end

  describe "reconciling the checkout against what was requested" do
    it "warns when the store drops the requested line item entirely" do
      checkout = incomplete_checkout.merge("line_items" => [])
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:warnings].join).to include("dropped the requested item")
    end

    it "warns when the store checks out a different quantity than requested" do
      checkout = incomplete_checkout.merge(
        "line_items" => [{ "item" => { "id" => "p1", "price" => 100 }, "quantity" => 3 }]
      )
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", qty: 1, yes: true).call

      expect(report[:warnings].join).to include("quantity 3")
    end

    it "warns when the store prices the item differently than its own catalog just quoted" do
      priced_product = { "id" => "p1", "title" => "Cold Brew",
                         "variants" => [{ "id" => "p1", "price" => { "amount" => 500, "currency" => "USD" } }] }
      checkout = incomplete_checkout.merge(
        "line_items" => [{ "item" => { "id" => "p1", "price" => 700 }, "quantity" => 1 }], "currency" => "USD"
      )
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [priced_product] },
                                       create_checkout: checkout
      )
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:warnings].join).to include("priced the item at 700")
    end

    it "never warns when the returned line item matches the request" do
      checkout = incomplete_checkout.merge(
        "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }]
      )
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true).call

      expect(report[:warnings]).to eq([])
    end

    it "warns when the store checks out in another currency than its own catalog quoted" do
      priced_product = { "id" => "p1", "title" => "Cold Brew",
                         "variants" => [{ "id" => "p1", "price" => { "amount" => 500, "currency" => "USD" } }] }
      checkout = incomplete_checkout.merge(
        "line_items" => [{ "item" => { "id" => "p1", "price" => 500 }, "quantity" => 1 }], "currency" => "EUR"
      )
      session = instance_double(
        Portage::Ucp::Client::Session, advertises?: true,
                                       search_catalog: { "ucp" => 1, "products" => [priced_product] },
                                       create_checkout: checkout
      )
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", dry_run: true).call

      expect(report[:warnings]).to eq(["Store checked out in EUR, not the catalog's USD."])
    end

    # Regression (ClawHub security audit): a mismatch only stopped the
    # purchase under PORTAGE_ABORT_ON_CHECKOUT_MISMATCH, so by default a
    # checkout that didn't match the request was paid for and reported
    # `purchased`. The variable is now a no-op, whatever it's set to.
    [nil, "1", "0", "false"].each do |value|
      it "stops a mismatched checkout before payment with PORTAGE_ABORT_ON_CHECKOUT_MISMATCH=#{value.inspect}" do
        checkout = incomplete_checkout.merge("line_items" => [])
        session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed_checkout)
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

        report = with_env("PORTAGE_ABORT_ON_CHECKOUT_MISMATCH" => value) do
          described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call
        end

        expect(report[:outcome]).to eq("checkout_mismatch")
        expect(report[:message]).to include("Aborted before purchase")
        expect(session).not_to have_received(:complete_checkout)
      end
    end

    it "stops a mismatched checkout on a --quote run even when it's within the quoted total" do
      checkout = incomplete_checkout.merge(
        "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 2 }], "currency" => "USD",
        "totals" => [{ "type" => "total", "amount" => 1000 }]
      )
      session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1",
                                   quote_total: 2400, quote_currency: "USD").call

      expect(report[:outcome]).to eq("checkout_mismatch")
      expect(session).not_to have_received(:complete_checkout)
    end

    describe "lines the person never asked for" do
      def checkout_with_extra(extra)
        incomplete_checkout.merge(
          "line_items" => [{ "item" => { "id" => "p1", "price" => 500 }, "quantity" => 1 }, extra]
        )
      end

      def buy_with(checkout)
        session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed_checkout)
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
        report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call
        [report, session]
      end

      it "stops a checkout carrying an extra, priced line before payment" do
        extra = { "item" => { "id" => "prot_1", "title" => "Shipping protection", "price" => 295 }, "quantity" => 1 }
        report, session = buy_with(checkout_with_extra(extra))

        expect(report[:outcome]).to eq("checkout_mismatch")
        expect(report[:warnings])
          .to eq(["Store added prot_1 Shipping protection to checkout, which wasn't requested."])
        expect(session).not_to have_received(:complete_checkout)
      end

      it "stops on an extra line whose cost it can't read" do
        report, session = buy_with(checkout_with_extra({ "item" => { "id" => "mystery" }, "quantity" => 1 }))

        expect(report[:outcome]).to eq("checkout_mismatch")
        expect(session).not_to have_received(:complete_checkout)
      end

      it "stops on a second line for the requested item, which would double the order" do
        duplicate = { "item" => { "id" => "p1", "price" => 500 }, "quantity" => 1 }
        report, = buy_with(checkout_with_extra(duplicate))

        expect(report[:outcome]).to eq("checkout_mismatch")
        expect(report[:warnings].join).to include("Store added p1")
      end

      it "lets a free extra line through, by its own total or by its price" do
        by_total = { "item" => { "id" => "gift", "title" => "Free sample", "price" => 300 }, "quantity" => 1,
                     "totals" => [{ "type" => "total", "amount" => 0 }] }
        by_price = { "item" => { "id" => "gift", "price" => 0 }, "quantity" => 2 }

        [by_total, by_price].each do |extra|
          report, session = buy_with(checkout_with_extra(extra))

          expect(report[:outcome]).to eq("purchased")
          expect(report[:warnings]).to eq([])
          expect(session).to have_received(:complete_checkout)
        end
      end

      it "flags an extra line on a dry run without stopping the preview" do
        extra = { "item" => { "id" => "upsell", "price" => 900 }, "quantity" => 1 }
        session = fake_session(advertises_checkout: true, checkout: checkout_with_extra(extra))
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

        report = described_class.new(url: "shop.example", query: "cold", dry_run: true).call

        expect(report).to include(outcome: "dry_run", checkout_mismatch: true)
      end
    end

    it "keeps a mismatched --dry-run a dry run, flagging that the real purchase would stop" do
      checkout = incomplete_checkout.merge("line_items" => [])
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", dry_run: true).call

      expect(report).to include(outcome: "dry_run", checkout_mismatch: true)
      expect(report[:message]).to include("a real purchase would stop with checkout_mismatch")
      expect(report[:warnings].join).to include("dropped the requested item")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "leaves the flag off a dry run whose checkout matches" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", dry_run: true).call

      expect(report[:outcome]).to eq("dry_run")
      expect(report).not_to have_key(:checkout_mismatch)
    end
  end

  describe "the decision layer's verdicts" do
    let(:priced_checkout) do
      incomplete_checkout.merge("currency" => "USD", "totals" => [{ "type" => "total", "amount" => 5000 }])
    end

    def buy(checkout:, completed: completed_checkout, **options)
      session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1",
                                   **options).call
      [report, session]
    end

    def policy(data)
      allow(Portage::Ucp::Policy).to receive(:load).and_return(Portage::Ucp::Policy.new(data: data))
    end

    # Stands in for a Decision::ModelBackends backend: answers the one noul
    # question ConfidenceCheck asks with a fixed yes-probability.
    def confidence_check(noul: nil, error: nil, threshold: 0.8, sent: [])
      backend = Object.new
      backend.define_singleton_method(:ask) do |questions:, state:|
        sent << state
        raise error if error

        questions.transform_values do
          Portage::Ucp::Decision::ModelBackends::Answer.new(type: "noul", confidence: nil, value: noul)
        end
      end
      Portage::Cli::ConfidenceCheck.new(backend: "fake", threshold: threshold, resolver: ->(_name) { backend })
    end

    it "records a passing escalation and policy verdict on a completed purchase" do
      report, = buy(checkout: priced_checkout)

      expect(report[:message]).to eq("Purchased.")
      expect(report[:decisions]).to eq(escalation: { escalate: false, reason: nil },
                                       policy: { allowed: true, reason: nil })
    end

    it "records requires_escalation as the escalation verdict" do
      report, = buy(checkout: incomplete_checkout.merge("status" => "requires_escalation"))

      expect(report[:decisions][:escalation]).to eq(escalate: true, reason: "requires_escalation")
    end

    it "records a mismatch as the escalation verdict" do
      checkout = incomplete_checkout.merge("line_items" => [])
      report, session = buy(checkout: checkout)

      expect(report[:decisions][:escalation]).to eq(escalate: true, reason: "mismatch")
      expect(session).not_to have_received(:complete_checkout)
    end

    # Dispatcher's own PolicyGuard runs only in-process, so before this
    # check a remote store never saw the buyer's caps at all.
    it "blocks a remote store's checkout over the buyer's per-transaction cap before completing it" do
      policy("per_transaction_cap" => { "amount" => 1000, "currency" => "USD" })
      report, session = buy(checkout: priced_checkout)

      expect(report[:message]).to start_with("Blocked by your spend policy (per_transaction_cap_exceeded)")
      expect(report[:decisions][:policy]).to eq(allowed: false, reason: "per_transaction_cap_exceeded")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "blocks a remote store that isn't on the buyer's merchant allowlist" do
      policy("merchant_allowlist" => ["other.example"])
      report, session = buy(checkout: priced_checkout)

      expect(report[:decisions][:policy]).to eq(allowed: false, reason: "merchant_not_allowlisted")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "carries the same verdicts in-process as in --json" do
      report, = buy(checkout: priced_checkout, confidence_check: confidence_check(noul: 0.3))

      expect(report[:decisions].keys).to eq(%i[escalation policy confidence])
      expect(JSON.parse(JSON.generate(report[:decisions]), symbolize_names: true)).to eq(report[:decisions])
    end

    it "asks no model anything when no decision backend is configured" do
      report, = buy(checkout: priced_checkout)

      expect(report[:decisions]).not_to have_key(:confidence)
    end

    it "completes when the confidence check clears the threshold" do
      report, = buy(checkout: priced_checkout, confidence_check: confidence_check(noul: 0.95))

      expect(report[:message]).to eq("Purchased.")
      expect(report[:decisions][:confidence]).to include(proceed: true, confidence: 0.95, threshold: 0.8)
    end

    it "holds the purchase and hands off the checkout when confidence is below the threshold" do
      checkout = priced_checkout.merge("continue_url" => "https://shop.example/checkout/1")
      report, session = buy(checkout: checkout, confidence_check: confidence_check(noul: 0.3))

      expect(report[:message]).to include("scored this checkout 0.3, below the 0.8 threshold")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/1")
      expect(report[:decisions][:confidence]).to include(proceed: false, reason: "below_threshold", confidence: 0.3)
      expect(session).not_to have_received(:complete_checkout)
    end

    it "fails closed when the decision backend can't answer" do
      error = Portage::Ucp::Decision::BackendNotConfiguredError.new("JEV_API_KEY is not set")
      report, session = buy(checkout: priced_checkout, confidence_check: confidence_check(error: error))

      expect(report[:message]).to include("couldn't answer", "JEV_API_KEY is not set")
      expect(report[:decisions][:confidence])
        .to include(proceed: false, reason: "backend_error", error: "JEV_API_KEY is not set")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "never asks for confidence on a run that isn't completing anything" do
      check = confidence_check(noul: 0.1)
      allow(check).to receive(:call).and_call_original
      buy(checkout: priced_checkout, dry_run: true, confidence_check: check)

      expect(check).not_to have_received(:call)
    end

    describe "what the confidence check sends to the backend" do
      let(:variant_product) do
        { "id" => "p1", "title" => "Cold Brew",
          "variants" => [{ "id" => "v1", "title" => "1L", "price" => { "amount" => 2000, "currency" => "USD" } }] }
      end

      # Everything a store might put on a checkout that must never leave
      # this process: a buyer block, a shipping address on the fulfillment
      # destination, payment handlers and instruments, links.
      let(:loaded_checkout) do
        { "id" => "chk_secret_id", "status" => "ready_for_complete", "currency" => "USD",
          "continue_url" => "https://shop.example/checkouts/chk_secret_id?key=ck_secret",
          "links" => [{ "type" => "terms_of_service", "url" => "https://shop.example/tos" }],
          "line_items" => [{ "id" => "li_1", "quantity" => 1,
                             "item" => { "id" => "v1", "title" => "Cold Brew 1L", "price" => 2000,
                                         "image_url" => "https://cdn.example/img.png" },
                             "totals" => [{ "type" => "subtotal", "amount" => 2000 },
                                          { "type" => "total", "amount" => 2000 }] }],
          "totals" => [{ "type" => "subtotal", "amount" => 2000 }, { "type" => "fulfillment", "amount" => 500 },
                       { "type" => "tax", "amount" => 200, "display_text" => "VAT for Jane Doe" },
                       { "type" => "total", "amount" => 2700 }],
          "discounts" => { "codes" => ["STAFF-ONLY-CODE"], "applied" => [{ "title" => "Welcome", "amount" => 0 }] },
          "buyer" => { "first_name" => "Jane", "last_name" => "Doe", "email" => "jane@example.com",
                       "phone_number" => "+15555550100" },
          "payment" => { "handlers" => [{ "id" => "shop_pay" }],
                         "instruments" => [{ "credential" => { "token" => "tok_live_secret" } }] },
          "fulfillment" => { "methods" => [{
            "id" => "m1", "type" => "shipping", "line_item_ids" => ["li_1"],
            "destinations" => [{ "id" => "d1", "street_address" => "1 Secret Lane", "address_locality" => "Erie",
                                 "postal_code" => "16501", "first_name" => "Jane", "last_name" => "Doe",
                                 "phone_number" => "+15555550100" }],
            "groups" => [{ "id" => "g1", "line_item_ids" => ["li_1"], "selected_option_id" => "o2",
                           "options" => [{ "id" => "o1", "title" => "Express",
                                           "totals" => [{ "type" => "total", "amount" => 1500 }] },
                                         { "id" => "o2", "title" => "Standard", "carrier" => "USPS",
                                           "totals" => [{ "type" => "total", "amount" => 500 }] }] }]
          }] } }
      end

      def buy_sending(checkout, sent, **options)
        session = instance_double(Portage::Ucp::Client::Session, advertises?: true,
                                                                 search_catalog: { "products" => [variant_product] },
                                                                 create_checkout: checkout,
                                                                 complete_checkout: completed_checkout)
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
        described_class.new(url: "shop.example", query: "cold brew", yes: true, payment_token: "tok_live_secret",
                            confidence_check: confidence_check(noul: 0.95, sent: sent), **options).call
      end

      it "never sends the payment token, address, buyer details, links, ids or codes" do
        sent = []
        with_env("PORTAGE_SHIP_STREET" => "1 Secret Lane", "PORTAGE_SHIP_EMAIL" => "jane@example.com") do
          buy_sending(loaded_checkout, sent)
        end

        expect(sent.length).to eq(1)
        ["tok_live_secret", "Secret Lane", "16501", "Erie", "Jane", "Doe", "jane@example.com", "+15555550100",
         "chk_secret_id", "ck_secret", "shop.example/checkouts", "shop.example/tos", "cdn.example",
         "STAFF-ONLY-CODE", "shop_pay", "USPS", "VAT for"].each do |secret|
          expect(sent.first).not_to include(secret)
        end
        expect(JSON.parse(sent.first).keys).to eq(%w[request checkout warnings])
      end

      it "sends the request, the picked item and a summary of what the store will charge" do
        sent = []
        buy_sending(loaded_checkout, sent)

        expect(JSON.parse(sent.first)).to eq(
          "request" => { "query" => "cold brew", "merchant" => "shop.example", "quantity" => 1, "item_id" => "v1",
                         "item_title" => "Cold Brew — 1L" },
          "checkout" => {
            "status" => "ready_for_complete", "currency" => "USD",
            "line_items" => [{ "item_id" => "v1", "title" => "Cold Brew 1L", "unit_price" => 2000, "quantity" => 1,
                               "totals" => [{ "type" => "subtotal", "amount" => 2000 },
                                            { "type" => "total", "amount" => 2000 }],
                               "requested" => true }],
            "totals" => [{ "type" => "subtotal", "amount" => 2000 }, { "type" => "fulfillment", "amount" => 500 },
                         { "type" => "tax", "amount" => 200 }, { "type" => "total", "amount" => 2700 }],
            "discounts" => [{ "title" => "Welcome", "amount" => 0 }],
            "shipping" => [{ "title" => "Standard", "amount" => 500 }]
          },
          "warnings" => []
        )
      end

      it "marks a free extra line as unrequested, for the model to judge" do
        sent = []
        gift = { "item" => { "id" => "gift", "title" => "Free tote", "price" => 0 }, "quantity" => 1 }
        buy_sending(loaded_checkout.merge("line_items" => loaded_checkout["line_items"] + [gift]), sent)

        lines = JSON.parse(sent.first).dig("checkout", "line_items")
        expect(lines.map { |line| [line["item_id"], line["requested"]] }).to eq([["v1", true], ["gift", false]])
      end

      it "sends the approved quote's pinned fields on a --quote run" do
        sent = []
        buy_sending(loaded_checkout, sent, product_id: "v1", quote_total: 2700, quote_currency: "USD",
                                           quote_store: "https://shop.example", quote_title: "Cold Brew 1L")

        expect(JSON.parse(sent.first)["approved_quote"]).to eq(
          "store" => "https://shop.example", "product_id" => "v1", "title" => "Cold Brew 1L", "quantity" => 1,
          "total" => 2700, "currency" => "USD"
        )
      end

      it "asks nothing about a checkout the deterministic check already stopped" do
        sent = []
        mismatched = loaded_checkout.merge("line_items" => [])
        report = buy_sending(mismatched, sent)

        expect(report[:outcome]).to eq("checkout_mismatch")
        expect(sent).to be_empty
      end

      it "asks nothing about a --quote run whose total went over the quote" do
        sent = []
        report = buy_sending(loaded_checkout, sent, quote_total: 2000, quote_currency: "USD",
                                                    quote_store: "https://shop.example")

        expect(report[:outcome]).to eq("quote_changed")
        expect(sent).to be_empty
      end

      it "asks nothing about a checkout the spend policy blocks" do
        policy("per_transaction_cap" => { "amount" => 1000, "currency" => "USD" })
        sent = []
        report = buy_sending(loaded_checkout, sent)

        expect(report[:outcome]).to eq("policy_blocked")
        expect(sent).to be_empty
      end
    end

    # PolicyGuard's rolling cap and velocity limit count the transaction
    # log, which only the own-store Dispatcher used to write. A remote
    # native-UCP purchase now lands there too, so those limits see it.
    describe "remote purchases in the transaction log" do
      # spec_helper points every default-built TransactionLog at the same
      # per-example file, so this reads what Buy wrote.
      let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }

      it "records a remote purchase as complete, under the merchant host" do
        buy(checkout: priced_checkout)

        expect(transaction_log.all).to contain_exactly(
          include("shop" => "shop.example", "checkout_id" => "chk_1", "status" => "complete", "amount" => 5000,
                  "currency" => "USD", "payment_token_ref" => Portage::Ucp::Support::TokenRef.for("tok_1"))
        )
      end

      it "blocks a second remote buy that would take the rolling spend over the cap" do
        policy("rolling_cap" => { "amount" => 8000, "currency" => "USD", "window_seconds" => 3600 })

        first, = buy(checkout: priced_checkout)
        second, session = buy(checkout: priced_checkout.merge("id" => "chk_2"))

        expect(first[:outcome]).to eq("purchased")
        expect(second[:outcome]).to eq("policy_blocked")
        expect(second[:decisions][:policy]).to eq(allowed: false, reason: "rolling_spend_cap_exceeded")
        expect(session).not_to have_received(:complete_checkout)
      end

      it "blocks a second remote buy past the velocity limit" do
        policy("velocity" => { "count" => 1, "window_seconds" => 3600 })

        buy(checkout: priced_checkout)
        second, = buy(checkout: priced_checkout.merge("id" => "chk_2"))

        expect(second[:decisions][:policy]).to eq(allowed: false, reason: "velocity_exceeded")
      end

      it "settles a completion the store escalated as failed, which neither limit counts" do
        buy(checkout: priced_checkout, completed: completed_checkout.merge("status" => "requires_escalation"))

        expect(transaction_log.all.map { |record| record["status"] }).to eq(["failed"])
      end

      it "settles a completion that raised as failed" do
        session = fake_session(advertises_checkout: true, checkout: priced_checkout)
        allow(session).to receive(:complete_checkout).and_raise(Portage::Ucp::Client::PaymentPermissionError, "no")
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

        report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

        expect(report[:outcome]).to eq("permission_denied")
        expect(transaction_log.all.map { |record| record["status"] }).to eq(["failed"])
      end

      it "records nothing for a purchase a gate held" do
        policy("merchant_allowlist" => ["other.example"])
        buy(checkout: priced_checkout)

        expect(transaction_log.all).to be_empty
      end

      it "still reports the purchase, with a warning, when the log can't be written afterwards" do
        log = Portage::Ucp::Support::TransactionLog.new
        allow(log).to receive(:complete).and_raise(Errno::EACCES, "transactions.json")

        report, = buy(checkout: priced_checkout, transaction_log: log)

        expect(report[:outcome]).to eq("purchased")
        expect(report[:warnings]).to include(a_string_including("couldn't be recorded in the transaction log"))
      end
    end
  end

  describe "pending handoff records (docs/plans/handoff-reconcile.md Phase 1)" do
    let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }
    let(:escalation) do
      { "id" => "chk_1", "status" => "requires_escalation",
        "links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }],
        "currency" => "USD", "totals" => [{ "type" => "total", "amount" => 4200 }],
        "expires_at" => "2026-09-25T00:00:00Z" }
    end

    def buy_and_escalate(**options)
      session = fake_session(advertises_checkout: true, checkout: escalation)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1", **options).call
    end

    it "reserves a pending, settled_by: shopper record when a checkout is handed off" do
      buy_and_escalate

      record = transaction_log.find("portage-buy:shop.example:chk_1")
      expect(record).to include("status" => "pending", "settled_by" => "shopper",
                                "handoff_reason" => "requires_escalation", "store_url" => "https://shop.example",
                                "checkout_id" => "chk_1", "shop" => "shop.example", "amount" => 4200,
                                "currency" => "USD", "expires_at" => "2026-09-25T00:00:00Z")
    end

    it "never reserves anything on --dry-run" do
      buy_and_escalate(dry_run: true, yes: false)

      expect(transaction_log.all).to be_empty
    end

    it "surfaces a warning on the report, without failing the hand-off, when the reserve write fails" do
      allow_any_instance_of(Portage::Ucp::Support::TransactionLog).to receive(:reserve)
        .and_raise(Errno::EACCES, "transactions.json")

      report = buy_and_escalate

      expect(report[:outcome]).to eq("requires_escalation")
      expect(report[:checkout_url]).to eq("https://shop.example/checkout/chk_1")
      expect(report[:warnings]).to include(a_string_including("Couldn't save this hand-off"))
    end

    describe "precheck spend mode" do
      around { |example| with_env("PORTAGE_HANDOFF_SPEND_MODE" => "precheck") { example.run } }

      it "suppresses auto-open and flags over_cap when this checkout would already exceed the buyer's cap" do
        allow(Portage::Ucp::Policy).to receive(:load)
          .and_return(Portage::Ucp::Policy.new(data: { "per_transaction_cap" => { "amount" => 100,
                                                                                  "currency" => "USD" } }))

        report = buy_and_escalate(auto_open: true)

        expect(report[:handoff][:over_cap]).to be true
        expect(report[:handoff][:opened]).to be false
      end

      it "still hands off normally when under the cap" do
        allow(Portage::Ucp::Policy).to receive(:load).and_return(Portage::Ucp::Policy.new(data: {}))

        report = buy_and_escalate

        expect(report[:handoff]).not_to have_key(:over_cap)
      end
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
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example", headers: Portage::Cli::UserAgent.headers).and_return(nil)
      stub_request(:get, "https://shop.example/").to_return(
        status: 200, body: '<html><head><link rel="ucp" href="https://ucp.shop.example/manifest"></head></html>'
      )
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://ucp.shop.example/manifest", headers: Portage::Cli::UserAgent.headers).and_return(session)

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

    # The loopback session's in-process Dispatcher records the purchase
    # itself, so Buy recording it too would count it twice against the
    # rolling cap and velocity limit.
    it "leaves recording an own-store purchase to Dispatcher" do
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
      allow(Portage::Ucp::Capabilities::FULFILLMENT).to receive(:advertised_for?).with(adapter).and_return(false)
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:for_adapter).with(adapter, anything).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:outcome]).to eq("purchased")
      expect(Portage::Ucp::Support::TransactionLog.new.all).to be_empty
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
      allow(Portage::Ucp::Capabilities::CHECKOUT).to receive(:advertised_for?)
        .with(adapter).and_raise("no payment_method configured on this Adapter")

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

  describe "WebMCP outbound (docs/plans/handoff-reconcile.md Phase 4)" do
    # list_tools: [] — an empty page, so Presets.detect (Phase 1) never
    # matches it and #webmcp_flow passes preset: nil through to connect,
    # same as before preset: existed.
    let(:bridge) { double("bridge", list_tools: []) }

    def stub_no_native_manifest
      allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html>nothing recognizable</html>")
    end

    let(:webmcp_checkout) do
      { "id" => "chk_1", "status" => "ready_for_complete", "totals" => [],
        "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }],
        "continue_url" => "https://shop.example/cart/c/chk_1" }
    end

    def webmcp_session(checkout: webmcp_checkout)
      instance_double(Portage::Ucp::Client::Session, advertises?: true,
                                                     search_catalog: { "products" => [product] },
                                                     create_checkout: checkout)
    end

    it "never touches WebMCP when no bridge is given (the default)" do
      stub_no_native_manifest
      expect(Portage::Ucp::WebMcp).not_to receive(:connect)

      report = described_class.new(url: "shop.example", query: "cold").call

      expect(report[:source]).to eq("none")
    end

    it "never touches WebMCP when native UCP discovery already answers" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      expect(Portage::Ucp::WebMcp).not_to receive(:connect)

      described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call
    end

    it "builds cart/checkout over WebMCP and always hands off (express_stop), never completing" do
      stub_no_native_manifest
      session = webmcp_session
      allow(Portage::Ucp::WebMcp).to receive(:connect).with(bridge: bridge, preset: nil).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1",
                                   webmcp_bridge: bridge).call

      expect(report[:source]).to eq("webmcp")
      expect(report[:outcome]).to eq("express_stop")
      expect(report[:handoff]).not_to be_nil
      expect(session).to have_received(:create_checkout)
    end

    # Regression: a real WebMcp.connect used to build a Session with nil
    # capabilities, so the cart/checkout gate never passed against a page and
    # the stubbed Sessions above hid it. This one goes through the real
    # connect, Transport and Session, with only the page faked.
    it "runs the WebMCP flow through the real connect against a page's tools" do
      stub_no_native_manifest
      answers = { "search_catalog" => { "products" => [product] }, "create_cart" => {},
                  "create_checkout" => webmcp_checkout }
      page = Class.new do
        define_method(:list_tools) { answers.keys.map { |name| { "name" => name, "inputSchema" => {} } } }
        define_method(:execute_tool) { |name, _input| answers.fetch(name) }
      end.new

      report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page).call

      expect(report[:source]).to eq("webmcp")
      expect(report[:outcome]).to eq("express_stop")
      expect(report[:checkout_url]).to eq("https://shop.example/cart/c/chk_1")
    end

    describe "Phase 1: platform presets and the hand-off checkout path" do
      # Same real-connect posture as the regression test above: Presets.detect
      # runs against this page's own tool names — no instance_double standing
      # in for #connect or for preset detection. Registers exactly Shopify's
      # fingerprint (Presets::SHOPIFY): no create_checkout tool at all, so
      # #webmcp_flow can only reach checkout through proceed_to_checkout.
      def shopify_shaped_page(cart:, handoff_result:, location: nil)
        names = %w[search_catalog browse_store get_product show_variant add_to_cart get_cart
                   update_cart_lines cancel_cart proceed_to_checkout manage_orders
                   search_shop_policies_and_faqs]
        answers = { "search_catalog" => { "products" => [product] }, "add_to_cart" => {}, "get_cart" => cart,
                    "proceed_to_checkout" => handoff_result }
        found_at = location
        Class.new do
          define_method(:list_tools) { names.map { |name| { "name" => name, "inputSchema" => {} } } }
          define_method(:execute_tool) { |name, _input| answers.fetch(name, {}) }
          define_method(:location) { found_at } if found_at
        end.new
      end

      let(:webmcp_cart) do
        { "id" => "cart_1", "currency" => "USD", "totals" => [{ "type" => "total", "amount" => 500 }],
          "line_items" => [{ "item" => { "id" => "p1", "price" => 500 }, "quantity" => 1 }] }
      end

      it "detects the Shopify preset from the page's own tools and hands off through proceed_to_checkout" do
        stub_no_native_manifest
        page = shopify_shaped_page(cart: webmcp_cart,
                                   handoff_result: { "url" => "https://shop.example/checkouts/c1" })

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page).call

        expect(report[:source]).to eq("webmcp")
        expect(report[:outcome]).to eq("express_stop")
        expect(report[:checkout_url]).to eq("https://shop.example/checkouts/c1")
        expect(report[:warnings]).to be_empty
      end

      it "falls back to the bridge's own location when the hand-off tool returns nothing url-shaped" do
        stub_no_native_manifest
        page = shopify_shaped_page(cart: webmcp_cart, handoff_result: {},
                                   location: "https://shop.example/checkouts/c1")

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page).call

        expect(report[:checkout_url]).to eq("https://shop.example/checkouts/c1")
      end

      # A library caller's dry_run: true used to be ignored here: the run
      # still added to the store's real cart and navigated the bridge's tab
      # to checkout. Nothing past the read-only search may run.
      it "stops before any cart mutation or hand-off on a dry run, reporting what it would have done" do
        stub_no_native_manifest
        page = shopify_shaped_page(cart: webmcp_cart,
                                   handoff_result: { "url" => "https://shop.example/checkouts/c1" })
        allow(page).to receive(:execute_tool).and_call_original

        report = described_class.new(url: "shop.example", query: "cold", yes: true, dry_run: true,
                                     webmcp_bridge: page).call

        expect(report[:source]).to eq("webmcp")
        expect(report[:outcome]).to eq("dry_run")
        expect(report[:message]).to include("Dry run")
        expect(report[:handoff]).to be_nil
        expect(report[:checkout_url]).to be_nil
        expect(report[:would]).to eq(line_items: [{ product_id: "p1", quantity: 1 }],
                                     handoff_checkout: "proceed_to_checkout", autofill: false)
        %w[add_to_cart get_cart proceed_to_checkout].each do |tool|
          expect(page).not_to have_received(:execute_tool).with(tool, anything)
        end
      end

      # Regression (ClawHub security audit follow-up): this flow used to put
      # a cart mismatch in `warnings` and still send the tab to checkout.
      context "when the store's cart doesn't match the request" do
        let(:mismatched_cart) do
          { "id" => "cart_1", "currency" => "USD", "totals" => [{ "type" => "total", "amount" => 1000 }],
            "line_items" => [{ "item" => { "id" => "p1", "price" => 500 }, "quantity" => 2 }] }
        end

        it "stops with checkout_mismatch before the hand-off tool, pointing at the cart page" do
          stub_no_native_manifest
          page = shopify_shaped_page(cart: mismatched_cart,
                                     handoff_result: { "url" => "https://shop.example/checkouts/c1" })
          allow(page).to receive(:execute_tool).and_call_original

          report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page).call

          expect(report[:source]).to eq("webmcp")
          expect(report[:outcome]).to eq("checkout_mismatch")
          expect(report[:decisions][:escalation]).to eq(escalate: true, reason: "mismatch")
          expect(report[:warnings]).to include("Store checked out quantity 2, not the requested 1.")
          expect(report[:checkout_url]).to eq("https://shop.example/cart")
          expect(report[:message]).to include("Nothing was bought, and checkout wasn't opened")
          expect(page).to have_received(:execute_tool).with("get_cart", anything)
          expect(page).not_to have_received(:execute_tool).with("proceed_to_checkout", anything)
        end

        it "stops the same way on a --yes run" do
          stub_no_native_manifest
          page = shopify_shaped_page(cart: mismatched_cart, handoff_result: {},
                                     location: "https://shop.example/checkouts/c1")
          allow(page).to receive(:execute_tool).and_call_original

          report = described_class.new(url: "shop.example", query: "cold", yes: true, webmcp_bridge: page).call

          expect(report[:outcome]).to eq("checkout_mismatch")
          expect(report[:checkout_url]).to eq("https://shop.example/cart")
          expect(page).not_to have_received(:execute_tool).with("proceed_to_checkout", anything)
        end
      end

      it "never auto-opens or notifies on a dry run" do
        stub_no_native_manifest
        page = shopify_shaped_page(cart: webmcp_cart, handoff_result: {},
                                   location: "https://shop.example/checkouts/c1")
        expect(Portage::Cli::CheckoutHandoff).not_to receive(:new)

        report = described_class.new(url: "shop.example", query: "cold", dry_run: true, webmcp_bridge: page).call

        expect(report[:outcome]).to eq("dry_run")
      end
    end

    describe "Phase 2: schema matching for an unrecognized page's tools" do
      around do |example|
        Dir.mktmpdir do |dir|
          @phase2_mappings_path = File.join(dir, "webmcp_mappings.json")
          example.run
        end
      end

      # A page whose tools use nobody-else's names — Presets.detect won't
      # match, and the tools don't happen to be named after the bare UCP
      # actions either, so #webmcp_flow's plain connect (no tool_names:)
      # won't advertise cart/checkout and #webmcp_matched_session (Matcher)
      # is what has to get this page bought at all. Real connect, real
      # Transport, real Matcher — no instance_double standing in for any of
      # them, same posture as the regression/Phase 1 tests above.
      def matcher_shaped_page(product_result:, checkout_result:)
        schemas = {
          "findProducts" => { "properties" => { "query" => {} } },
          "fetchProductDetails" => { "properties" => { "product_id" => {} } },
          "viewCart" => { "properties" => { "cart_id" => {} } },
          "addItemToCart" => { "properties" => { "product_id" => {}, "quantity" => {} } },
          "startCheckout" => { "properties" => { "line_items" => {} } }
        }
        answers = { "findProducts" => product_result, "startCheckout" => checkout_result }
        Class.new do
          define_method(:list_tools) do
            schemas.map { |name, props| { "name" => name, "inputSchema" => props, "description" => "#{name}." } }
          end
          define_method(:execute_tool) { |name, _input| answers.fetch(name, {}) }
        end.new
      end

      let(:matched_checkout) do
        { "id" => "chk_2", "status" => "ready_for_complete", "totals" => [],
          "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }],
          "continue_url" => "https://shop.example/cart/c/chk_2" }
      end

      it "buys through a proposed mapping once the shopper confirms it interactively" do
        stub_no_native_manifest
        page = matcher_shaped_page(product_result: { "products" => [product] }, checkout_result: matched_checkout)
        confirm = Portage::Cli::WebmcpMappingConfirm.new(interactive: true, input: StringIO.new("y\n"),
                                                         output: StringIO.new)

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page,
                                     webmcp_mapping_confirm: confirm).call

        expect(report[:source]).to eq("webmcp")
        expect(report[:outcome]).to eq("express_stop")
        expect(report[:checkout_url]).to eq("https://shop.example/cart/c/chk_2")
      end

      it "stops with webmcp_mapping_unconfirmed and hands back the proposal when it can't be confirmed" do
        stub_no_native_manifest
        page = matcher_shaped_page(product_result: { "products" => [product] }, checkout_result: matched_checkout)
        confirm = Portage::Cli::WebmcpMappingConfirm.new(interactive: false)

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page,
                                     webmcp_mapping_confirm: confirm).call

        expect(report[:source]).to eq("webmcp")
        expect(report[:outcome]).to eq("webmcp_mapping_unconfirmed")
        expect(report[:tool_names_proposal]["create_cart"][:tool_name]).to eq("addItemToCart")
        expect(report[:tool_names_proposal]["create_checkout"][:tool_name]).to eq("startCheckout")
      end

      it "reuses a previously confirmed mapping with no prompt at all, keyed by the tool fingerprint" do
        stub_no_native_manifest
        page = matcher_shaped_page(product_result: { "products" => [product] }, checkout_result: matched_checkout)
        mappings = Portage::Cli::WebmcpMappings.new(path: @phase2_mappings_path, data: {})
        mappings.confirm!(page.list_tools, tool_names: { "search_catalog" => "findProducts",
                                                         "create_cart" => "addItemToCart",
                                                         "create_checkout" => "startCheckout" })
        # interactive: false proves no prompt is needed — a confirmed mapping
        # skips WebmcpMappingConfirm entirely.
        confirm = Portage::Cli::WebmcpMappingConfirm.new(interactive: false)

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page,
                                     webmcp_mappings: mappings, webmcp_mapping_confirm: confirm).call

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:checkout_url]).to eq("https://shop.example/cart/c/chk_2")
      end

      it "never falls back to Matcher for a page that already answers the bare UCP action names" do
        stub_no_native_manifest
        answers = { "search_catalog" => { "products" => [product] }, "create_cart" => {},
                    "create_checkout" => webmcp_checkout }
        page = Class.new do
          define_method(:list_tools) { answers.keys.map { |name| { "name" => name, "inputSchema" => {} } } }
          define_method(:execute_tool) { |name, _input| answers.fetch(name) }
        end.new
        expect(Portage::Ucp::WebMcp::Matcher).not_to receive(:propose)

        described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page).call
      end
    end

    describe "Phase 3: approved autofill of the store's checkout" do
      # Same Shopify-shaped fake page as the Phase 1 block (duplicated
      # rather than shared, so this block reads standalone), now offering
      # #autofill/#headless? too — everything Bridges::ScriptEvaluator
      # would, without a real browser (the plan's own posture for Phase 3:
      # filling logic is tested against a fake/stubbed bridge).
      def shopify_shaped_page_with_autofill(headless:, autofill_result:)
        names = %w[search_catalog browse_store get_product show_variant add_to_cart get_cart
                   update_cart_lines cancel_cart proceed_to_checkout manage_orders
                   search_shop_policies_and_faqs]
        answers = { "search_catalog" => { "products" => [product] }, "add_to_cart" => {}, "get_cart" => webmcp_cart,
                    "proceed_to_checkout" => { "url" => "https://shop.example/checkouts/c1" } }
        result = autofill_result
        Class.new do
          define_method(:list_tools) { names.map { |name| { "name" => name, "inputSchema" => {} } } }
          define_method(:execute_tool) { |name, _input| answers.fetch(name, {}) }
          define_method(:headless?) { headless }
          define_method(:autofill) { |*_args, **_kwargs| result }
        end.new
      end

      let(:webmcp_cart) do
        { "id" => "cart_1", "currency" => "USD", "totals" => [{ "type" => "total", "amount" => 500 }],
          "line_items" => [{ "item" => { "id" => "p1", "price" => 500 }, "quantity" => 1 }] }
      end

      let(:ship_env) do
        { "PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
          "PORTAGE_SHIP_POSTAL_CODE" => "16501", "PORTAGE_SHIP_EMAIL" => "buyer@example.com" }
      end

      let(:approving_confirm) do
        Portage::Cli::WebmcpAutofillConfirm.new(interactive: true, input: StringIO.new("y\n"), output: StringIO.new)
      end

      it "never attempts autofill at all when the mode isn't approved (the default)" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(headless: false, autofill_result: { "blocked" => nil,
                                                                                     "filled" => [], "unmatched" => [],
                                                                                     "rate" => [] })
        expect(page).not_to receive(:autofill)

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page,
                              webmcp_autofill_confirm: approving_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report).not_to have_key(:autofill)
      end

      it "fills the approved fields once the shopper confirms them, opted in via autofill:" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(
          headless: false,
          autofill_result: { "blocked" => nil, "filled" => ["email", "shipping address-line1"], "unmatched" => [],
                             "rate" => ["Standard shipping"] }
        )

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: approving_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:autofill]).to eq(outcome: "autofill_filled", filled: ["email", "shipping address-line1"],
                                        unmatched: [], rate: ["Standard shipping"])
      end

      it "never fills anything the shopper declines, and never calls the bridge at all" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(headless: false, autofill_result: { "blocked" => nil,
                                                                                     "filled" => [], "unmatched" => [],
                                                                                     "rate" => [] })
        expect(page).not_to receive(:autofill)
        declining_confirm = Portage::Cli::WebmcpAutofillConfirm.new(interactive: true, input: StringIO.new("n\n"),
                                                                    output: StringIO.new)

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: declining_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:autofill]).to eq(outcome: "autofill_declined")
      end

      it "reports autofill_needs_headed_browser for a headless bridge, never touching the page's fields" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(headless: true, autofill_result: nil)
        expect(page).not_to receive(:autofill)

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: approving_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:autofill][:outcome]).to eq("autofill_needs_headed_browser")
      end

      it "reports autofill_blocked and fills nothing when the checkout page signals a CAPTCHA/challenge" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(
          headless: false,
          autofill_result: { "blocked" => "captcha", "filled" => [], "unmatched" => ["email"], "rate" => [] }
        )

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: approving_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:autofill][:outcome]).to eq("autofill_blocked")
        expect(report[:autofill][:filled]).to be_empty
      end

      it "never even asks to confirm when nothing is configured to fill" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(headless: false, autofill_result: nil)
        confirm = instance_double(Portage::Cli::WebmcpAutofillConfirm)
        expect(confirm).not_to receive(:call)

        report = with_env({ "PORTAGE_SHIP_STREET" => nil, "PORTAGE_SHIP_CITY" => nil, "PORTAGE_SHIP_COUNTRY" => nil,
                            "PORTAGE_SHIP_POSTAL_CODE" => nil, "PORTAGE_SHIP_EMAIL" => nil }) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: confirm).call
        end

        expect(report).not_to have_key(:autofill)
      end

      # Never a card/account field, never the pay button: WebmcpAutofillFields
      # (the only thing that ever builds `fields`) has no path to a payment
      # field at all, and the run still ends in express_stop — the shopper
      # finishes payment themselves on the store's own page, exactly as
      # before Phase 3 existed.
      it "still stops at payment and hands off as express_stop, even with autofill filled" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(
          headless: false,
          autofill_result: { "blocked" => nil, "filled" => ["email"], "unmatched" => [], "rate" => [] }
        )

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              webmcp_autofill_confirm: approving_confirm).call
        end

        expect(report[:outcome]).to eq("express_stop")
        expect(report[:checkout_url]).to eq("https://shop.example/checkouts/c1")
      end

      context "when the store's cart doesn't match the request" do
        let(:webmcp_cart) do
          { "id" => "cart_1", "currency" => "USD", "totals" => [{ "type" => "total", "amount" => 500 }],
            "line_items" => [{ "item" => { "id" => "p2", "price" => 500 }, "quantity" => 1 }] }
        end

        it "never asks to autofill or types into the page, stopping with checkout_mismatch" do
          stub_no_native_manifest
          page = shopify_shaped_page_with_autofill(headless: false, autofill_result: nil)
          expect(page).not_to receive(:autofill)
          confirm = instance_double(Portage::Cli::WebmcpAutofillConfirm)
          expect(confirm).not_to receive(:call)

          report = with_env(ship_env) do
            described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                                webmcp_autofill_confirm: confirm).call
          end

          expect(report[:outcome]).to eq("checkout_mismatch")
          expect(report).not_to have_key(:autofill)
          expect(report[:warnings]).to include("Store dropped the requested item (p1) from checkout.")
        end
      end

      it "never prompts or types into the page on a dry run, only reporting that autofill would run" do
        stub_no_native_manifest
        page = shopify_shaped_page_with_autofill(headless: false, autofill_result: nil)
        expect(page).not_to receive(:autofill)
        confirm = instance_double(Portage::Cli::WebmcpAutofillConfirm)
        expect(confirm).not_to receive(:call)

        report = with_env(ship_env) do
          described_class.new(url: "shop.example", query: "cold", webmcp_bridge: page, autofill: true,
                              dry_run: true, webmcp_autofill_confirm: confirm).call
        end

        expect(report[:outcome]).to eq("dry_run")
        expect(report[:would][:autofill]).to be(true)
        expect(report).not_to have_key(:autofill)
      end
    end

    it "reserves a pending shopper handoff record for the express-stop checkout" do
      stub_no_native_manifest
      allow(Portage::Ucp::WebMcp).to receive(:connect).with(bridge: bridge, preset: nil).and_return(webmcp_session)
      transaction_log = Portage::Ucp::Support::TransactionLog.new

      described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call

      record = transaction_log.find("portage-buy:shop.example:chk_1")
      expect(record).to include("status" => "pending", "settled_by" => "shopper", "handoff_reason" => "express_stop")
    end

    it "skips a store with no cart/checkout capability over WebMCP, falling through to adapter detection" do
      stub_no_native_manifest
      no_checkout_session = instance_double(Portage::Ucp::Client::Session, advertises?: false)
      allow(Portage::Ucp::WebMcp).to receive(:connect).with(bridge: bridge, preset: nil).and_return(no_checkout_session)
      allow(Portage::Ucp::Resolver).to receive(:detect_platform).and_return(nil)

      report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call

      expect(report[:source]).to eq("none")
    end

    it "reports webmcp_not_installed instead of raising when portage-ucp-webmcp isn't available" do
      stub_no_native_manifest
      allow(Portage::Cli::Webmcp).to receive(:available?).and_return(false)
      expect(Portage::Ucp::WebMcp).not_to receive(:connect)

      report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call

      expect(report[:outcome]).to eq("webmcp_not_installed")
      expect(report[:source]).to eq("webmcp")
    end

    it "reports a webmcp_error instead of raising when the bridge blows up" do
      stub_no_native_manifest
      allow(Portage::Ucp::WebMcp).to receive(:connect)
        .and_raise(Portage::Ucp::WebMcp::BridgeError, "page has no modelContext")

      report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call

      expect(report[:outcome]).to eq("webmcp_error")
      expect(report[:message]).to include("page has no modelContext")
    end

    describe "webmcp_checkout_mode=token" do
      around { |example| with_env("PORTAGE_WEBMCP_CHECKOUT_MODE" => "token") { example.run } }

      it "refuses rather than silently behaving like express_stop" do
        stub_no_native_manifest
        allow(Portage::Ucp::WebMcp).to receive(:connect).with(bridge: bridge, preset: nil).and_return(webmcp_session)

        report = described_class.new(url: "shop.example", query: "cold", webmcp_bridge: bridge).call

        expect(report[:outcome]).to eq("webmcp_token_unsupported")
        expect(report[:checkout]).to be false
      end
    end
  end

  describe "hand-off targets + hand-off-only hosts (docs/plans/buy-skill-and-local-browser.md Phase 5)" do
    describe "Tier C: hand-off-only hosts" do
      it "never sends a request to Amazon — no UCP probe, no homepage fetch, no cart" do
        expect(Portage::Ucp::Client).not_to receive(:discover)
        expect(Portage::Cli::HomepageFetch).not_to receive(:call)

        report = described_class.new(url: "https://www.amazon.co.uk", query: "kettle", dry_run: true).call

        expect(a_request(:any, /.*/)).not_to have_been_made
        expect(report[:outcome]).to eq("handoff_only")
      end

      it "reports handoff_only with the retailer's own search URL and the legal notice" do
        report = described_class.new(url: "https://www.amazon.co.uk", query: "kettle", dry_run: true).call

        expect(report[:outcome]).to eq("handoff_only")
        expect(report[:source]).to eq("handoff_only")
        expect(report[:checkout]).to be false
        expect(report[:browse]).to be false
        expect(report[:checkout_url]).to eq("https://www.amazon.co.uk/s?k=kettle")
        expect(report[:legal_notice]).to eq(Portage::Cli::HandoffOnly::LEGAL_NOTICE)
      end

      it "builds a cart-add URL when a product id is known" do
        report = described_class.new(url: "https://www.amazon.com", query: "kettle", product_id: "B000123",
                                     qty: 2, dry_run: true).call

        expect(report[:checkout_url])
          .to eq("https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B000123&Quantity.1=2")
      end

      it "falls back to the origin's homepage for a user-added host with no known search pattern" do
        Portage::Cli::Config.load.set("handoff_only_hosts", ["shop.example"])

        report = described_class.new(url: "https://shop.example", query: "kettle", dry_run: true).call

        expect(report[:outcome]).to eq("handoff_only")
        expect(report[:checkout_url]).to eq("https://shop.example/")
      end

      it "an Amazon offer's own default-hand-off-target list is honored — Amazon opens like any other hand-off" do
        allow_any_instance_of(Portage::Cli::CheckoutHandoff).to receive(:system).and_return(true)

        report = described_class.new(url: "https://www.amazon.co.uk", query: "kettle", auto_open: true).call

        expect(report[:handoff]).to include(opened: true, handoff_target: "default")
      end

      it "never opens anything on --dry-run" do
        allow(Portage::Cli::CheckoutHandoff).to receive(:new)

        report = described_class.new(url: "https://www.amazon.co.uk", query: "kettle", dry_run: true).call

        expect(report[:handoff]).to be_nil
        expect(Portage::Cli::CheckoutHandoff).not_to have_received(:new)
      end

      it "a user can drop Amazon from the list entirely, restoring normal buy behavior" do
        Portage::Cli::Config.load.set("handoff_only_hosts", [])
        session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

        report = described_class.new(url: "https://www.amazon.co.uk", query: "kettle", yes: true).call

        expect(report[:outcome]).not_to eq("handoff_only")
      end
    end

    describe "Phase 7: retailer offer source hosts (docs/plans/buy-skill-and-local-browser.md Phase 7)" do
      it "routes walmart.com straight to hand-off, using the exact page picked from find" do
        expect(Portage::Ucp::Client).not_to receive(:discover)
        expect(Portage::Cli::HomepageFetch).not_to receive(:call)

        report = described_class.new(url: "https://www.walmart.com/ip/kettle/123", query: "kettle",
                                     dry_run: true).call

        expect(a_request(:any, /.*/)).not_to have_been_made
        expect(report[:outcome]).to eq("handoff_only")
        expect(report[:checkout_url]).to eq("https://www.walmart.com/ip/kettle/123")
        expect(report[:legal_notice]).to eq(Portage::Cli::HandoffOnly::LEGAL_NOTICE)
      end

      it "does the same for ebay.com and bestbuy.com — neither has an adapter this gem ships" do
        %w[https://www.ebay.com/itm/1 https://www.bestbuy.com/site/1.p].each do |url|
          report = described_class.new(url: url, query: "kettle", dry_run: true).call

          expect(report[:outcome]).to eq("handoff_only")
          expect(report[:checkout_url]).to eq(url)
        end
      end

      it "routes an ordinary buyer to hand-off on etsy.com when no ETSY_* seller credentials are set" do
        with_env("ETSY_ACCESS_TOKEN" => nil, "ETSY_API_KEY" => nil, "ETSY_SHOP_ID" => nil) do
          report = described_class.new(url: "https://www.etsy.com/listing/123", query: "kettle",
                                       dry_run: true).call

          expect(report[:outcome]).to eq("handoff_only")
          expect(report[:checkout_url]).to eq("https://www.etsy.com/listing/123")
        end
      end

      it "leaves etsy.com to the existing seller adapter once the shop owner's own ETSY_* creds are set" do
        with_env("ETSY_ACCESS_TOKEN" => "tok", "ETSY_API_KEY" => "key", "ETSY_SHOP_ID" => "1") do
          allow(Portage::Ucp::Client).to receive(:discover).and_return(nil)
          allow(Portage::Cli::HomepageFetch).to receive(:call).and_return([nil, {}])

          report = described_class.new(url: "https://www.etsy.com/listing/123", query: "kettle",
                                       dry_run: true).call

          expect(report[:outcome]).not_to eq("handoff_only")
        end
      end

      it "a non-Amazon retail-offer host still never opens on --dry-run" do
        allow(Portage::Cli::CheckoutHandoff).to receive(:new)

        report = described_class.new(url: "https://www.bestbuy.com/site/1.p", query: "kettle", dry_run: true).call

        expect(report[:handoff]).to be_nil
        expect(Portage::Cli::CheckoutHandoff).not_to have_received(:new)
      end
    end

    describe "--handoff-target" do
      def dead_end_checkout
        incomplete_checkout.merge("links" => [{ "type" => "checkout", "url" => "https://shop.example/checkout/chk_1" }])
      end

      def stub_dead_end
        session = fake_session(advertises_checkout: true, checkout: dead_end_checkout)
        allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      end

      it "print: never opens anything, just reports the URL and the target" do
        stub_dead_end
        allow(Portage::Cli::CheckoutHandoff).to receive(:new)

        report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "print")).call

        expect(report[:handoff]).to include(opened: false, handoff_target: "print")
        expect(Portage::Cli::CheckoutHandoff).not_to have_received(:new)
      end

      it "profile: with no browser profile bridge attached, reports that and behaves like print " \
         "(docs/plans/buy-skill-and-local-browser.md Phase 6 — Cli.profile_webmcp_bridge attaches one; " \
         "Buy itself never builds its own)" do
        stub_dead_end

        report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "profile")).call

        expect(report[:handoff]).to include(opened: false, handoff_target: "profile")
        expect(report[:handoff][:target_message]).to include("portage browser profile open")
      end

      it "profile: with a browser profile bridge attached, navigates it to the checkout URL and reports opened" do
        stub_dead_end
        bridge = instance_double(Portage::Cli::BrowserProfile::Bridge)
        allow(bridge).to receive(:respond_to?).with(:navigate).and_return(true)
        expect(bridge).to receive(:navigate).with(kind_of(String))

        report = described_class.new(url: "shop.example", query: "cold", yes: true, webmcp_bridge: bridge,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "profile")).call

        expect(report[:handoff]).to include(opened: true, handoff_target: "profile")
      end

      it "profile: reports the link instead of raising when the bridge fails to navigate" do
        stub_dead_end
        bridge = instance_double(Portage::Cli::BrowserProfile::Bridge)
        allow(bridge).to receive(:respond_to?).with(:navigate).and_return(true)
        allow(bridge).to receive(:navigate).and_raise("profile process died")

        report = described_class.new(url: "shop.example", query: "cold", yes: true, webmcp_bridge: bridge,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "profile")).call

        expect(report[:handoff]).to include(opened: false, handoff_target: "profile")
        expect(report[:handoff][:target_message]).to include("profile process died")
      end

      it "agent:<name> is never invoked when the name isn't approved in config" do
        stub_dead_end

        report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "agent:openclaw")).call

        expect(report[:handoff]).to include(opened: false, handoff_target: "agent:openclaw", agent_delivered: false)
        expect(report[:handoff][:agent_error]).to include("openclaw").and include("approved")
      end

      it "agent:<name> is invoked with the same payload --notify-webhook sends, once approved" do
        stub_dead_end
        Portage::Cli::Config.load.set("handoff_agents",
                                      { "openclaw" => { "webhook" => "https://agent.example/hook",
                                                        "approved" => true } })
        stub = stub_request(:post, "https://agent.example/hook")
               .with(body: hash_including("event" => "checkout_handoff",
                                          "checkout_url" => "https://shop.example/checkout/chk_1",
                                          "store" => "https://shop.example", "query" => "cold"))
               .to_return(status: 200, body: "ok")

        report = described_class.new(url: "shop.example", query: "cold", yes: true,
                                     handoff_target: Portage::Cli::HandoffTarget.new(override: "agent:openclaw")).call

        expect(report[:handoff]).to include(agent_delivered: true, agent_error: nil, opened: false)
        expect(stub).to have_been_requested
      end

      it "the agent payload carries no shipping/credential fields beyond the checkout URL" do
        stub_dead_end
        Portage::Cli::Config.load.set("handoff_agents",
                                      { "openclaw" => { "webhook" => "https://agent.example/hook",
                                                        "approved" => true } })
        sent_body = nil
        stub_request(:post, "https://agent.example/hook")
          .to_return do |request|
          sent_body = request.body
          { status: 200, body: "ok" }
        end

        described_class.new(url: "shop.example", query: "cold", yes: true,
                            handoff_target: Portage::Cli::HandoffTarget.new(override: "agent:openclaw")).call

        body = JSON.parse(sent_body)
        expect(body.keys).not_to include("payment_token", "shipping_address", "card")
      end

      it "an unknown --handoff-target value raises ArgumentError, caught before any checkout is attempted" do
        expect { Portage::Cli::HandoffTarget.new(override: "nowhere") }.to raise_error(ArgumentError)
      end
    end
  end
end

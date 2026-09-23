require "spec_helper"

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
  end

  describe "native UCP, cart+checkout advertised" do
    it "creates a checkout and reports it awaiting confirmation without --yes" do
      session = fake_session(advertises_checkout: true, checkout: incomplete_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example").and_return(session)

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
                                     notified: false, notify_error: nil)
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

    it "aborts before completion when PORTAGE_ABORT_ON_CHECKOUT_MISMATCH is set" do
      checkout = incomplete_checkout.merge("line_items" => [])
      session = fake_session(advertises_checkout: true, checkout: checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = with_env("PORTAGE_ABORT_ON_CHECKOUT_MISMATCH" => "1") do
        described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call
      end

      expect(report[:message]).to include("Aborted before purchase")
      expect(session).not_to have_received(:complete_checkout)
    end

    it "only warns, without aborting, when PORTAGE_ABORT_ON_CHECKOUT_MISMATCH is unset" do
      checkout = incomplete_checkout.merge("line_items" => [])
      session = fake_session(advertises_checkout: true, checkout: checkout, completed: completed_checkout)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = described_class.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1").call

      expect(report[:message]).to eq("Purchased.")
      expect(session).to have_received(:complete_checkout)
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
    def confidence_check(noul: nil, error: nil, threshold: 0.8)
      backend = Object.new
      backend.define_singleton_method(:ask) do |questions:, **|
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

    it "records a mismatch escalation under PORTAGE_ABORT_ON_CHECKOUT_MISMATCH" do
      checkout = incomplete_checkout.merge("line_items" => [])
      report, session = with_env("PORTAGE_ABORT_ON_CHECKOUT_MISMATCH" => "1") { buy(checkout: checkout) }

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
end

require "spec_helper"
require "tmpdir"
require_relative "cli/browser_import/fixtures"

RSpec.describe Portage::Cli do
  let(:report) do
    { url: "https://shop.example", source: "native_ucp", browse: true, checkout: true,
      products: [{ "id" => "p1", "title" => "Cold Brew" }], checkout_url: nil, message: "ok" }
  end

  before do
    allow(Portage::Cli::History).to receive(:new)
      .and_return(instance_double(Portage::Cli::History, record_search: nil, record_purchase: nil))
  end

  describe ".run" do
    it "prints usage and returns 1 for an unknown command" do
      expect { expect(described_class.run(["nope"])).to eq(1) }.to output.to_stderr
    end

    it "prints the version and returns 0 for --version, -v, and version" do
      %w[--version -v version].each do |flag|
        expect { expect(described_class.run([flag])).to eq(0) }
          .to output("#{Portage::Cli::VERSION}\n").to_stdout
      end
    end

    it "prints usage and returns 1 when buy has no url" do
      expect { expect(described_class.run(["buy"])).to eq(1) }.to output.to_stderr
    end

    it "dispatches buy to Portage::Cli::Buy with the parsed options" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      described_class.run(%w[buy shop.example --query cold --qty 2 --payment-token tok --yes --dry-run])

      expect(captured).to include(url: "shop.example", query: "cold", qty: 2, payment_token: "tok",
                                  yes: true, dry_run: true)
    end

    it "hands --max-price to Buy too, so a url's own catalog is held to it" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      described_class.run(%w[buy shop.example --query cold --max-price 600])

      expect(captured).to include(url: "shop.example", max_price: 60_000)
    end

    it "prints JSON when --json is given, and passes json: true to Buy (Phase 2's mapping-confirm gate reads it)" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      output = nil
      expect { output = capture_stdout { described_class.run(%w[buy shop.example --json]) } }.not_to raise_error

      expect(captured).to include(json: true)
      expect(JSON.parse(output)["source"]).to eq("native_ucp")
    end

    it "passes json: false to Buy when --json isn't given" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      described_class.run(%w[buy shop.example --query cold])

      expect(captured).to include(json: false)
    end

    it "builds Buy's confidence check from --decision-backend and --min-confidence" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      capture_stdout { described_class.run(%w[buy shop.example --decision-backend jev --min-confidence 0.9]) }

      expect(captured[:confidence_check]).to be_enabled
      expect(captured[:confidence_check].threshold).to eq(0.9)
    end

    it "refuses to start a buy with an out-of-range --min-confidence" do
      allow(Portage::Cli::Buy).to receive(:new)

      expect { expect(described_class.run(%w[buy shop.example --min-confidence 2])).to eq(1) }
        .to output(/between 0.0 and 1.0/).to_stderr
      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "ignores a garbage PORTAGE_MIN_CONFIDENCE while no decision backend is selected" do
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: report))

      status = nil
      with_env("PORTAGE_DECISION_BACKEND" => nil, "PORTAGE_MIN_CONFIDENCE" => "high") do
        capture_stdout { status = described_class.run(%w[buy shop.example]) }
      end

      expect(status).to eq(0)
      expect(Portage::Cli::Buy).to have_received(:new)
    end

    it "still refuses a garbage PORTAGE_MIN_CONFIDENCE once a decision backend is selected" do
      allow(Portage::Cli::Buy).to receive(:new)

      with_env("PORTAGE_DECISION_BACKEND" => "jev", "PORTAGE_MIN_CONFIDENCE" => "high") do
        expect { expect(described_class.run(%w[buy shop.example])).to eq(1) }.to output(/"high"/).to_stderr
      end
      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    describe "--handoff-target (docs/plans/buy-skill-and-local-browser.md Phase 5)" do
      it "builds and passes a validated HandoffTarget to Buy" do
        captured = nil
        allow(Portage::Cli::Buy).to receive(:new) { |**opts|
          captured = opts
          instance_double(Portage::Cli::Buy, call: report)
        }

        described_class.run(%w[buy shop.example --query cold --handoff-target print])

        expect(captured[:handoff_target]).to be_a(Portage::Cli::HandoffTarget)
        expect(captured[:handoff_target]).to be_print
      end

      it "defaults to the \"default\" target when the flag is omitted" do
        captured = nil
        allow(Portage::Cli::Buy).to receive(:new) { |**opts|
          captured = opts
          instance_double(Portage::Cli::Buy, call: report)
        }

        described_class.run(%w[buy shop.example --query cold])

        expect(captured[:handoff_target]).to be_default
      end

      it "refuses an unknown --handoff-target value, before ever building Buy" do
        allow(Portage::Cli::Buy).to receive(:new)

        expect { expect(described_class.run(%w[buy shop.example --handoff-target nowhere])).to eq(1) }
          .to output(/Unknown --handoff-target/).to_stderr
        expect(Portage::Cli::Buy).not_to have_received(:new)
      end
    end

    describe "a refused option under --json" do
      before { allow(Portage::Cli::Buy).to receive(:new) }

      def refused(argv)
        status = nil
        stdout = nil
        expect { stdout = capture_stdout { status = described_class.run(argv) } }.not_to output.to_stderr
        [status, JSON.parse(stdout)]
      end

      it "reports an out-of-range --min-confidence as outcome invalid_option" do
        status, report = refused(%w[buy shop.example --min-confidence 2 --json])

        expect(status).to eq(1)
        expect(report).to include("outcome" => "invalid_option", "url" => "shop.example", "checkout" => false)
        expect(report["message"]).to include("between 0.0 and 1.0")
        expect(Portage::Cli::Buy).not_to have_received(:new)
      end

      it "reports a flag OptionParser can't read the same way, wherever --json sits" do
        status, report = refused(%w[buy shop.example --min-confidence high --json])

        expect(status).to eq(1)
        expect(report).to include("outcome" => "invalid_option")
        expect(report["message"]).to include("--min-confidence high")
      end

      it "reports an unknown --handoff-target the same way" do
        status, report = refused(%w[buy shop.example --handoff-target nowhere --json])

        expect(status).to eq(1)
        expect(report).to include("outcome" => "invalid_option")
        expect(report["message"]).to include("Unknown --handoff-target")
      end
    end

    it "prints the report's decision verdicts" do
      decided = report.merge(decisions: { policy: { allowed: false, reason: "merchant_not_allowlisted" } })
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: decided))

      output = capture_stdout { described_class.run(%w[buy shop.example]) }

      expect(output).to include("decision policy: allowed=false reason=merchant_not_allowlisted")
    end

    it "returns 0 when the report has browse or checkout, 1 otherwise" do
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: report))
      expect(described_class.run(%w[buy shop.example])).to eq(0)

      dead_end = report.merge(browse: false, checkout: false)
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: dead_end))
      expect(described_class.run(%w[buy shop.example])).to eq(1)
    end
  end

  describe "find" do
    let(:offer) do
      { store: "https://shop.example", source: "duckduckgo", checkout: true,
        product_id: "p1", title: "Cold Brew", amount: 2400, currency: "USD", url: nil }
    end
    let(:found) { { query: "cold", candidates: [], stores: [], offers: [offer], message: "Found 1 offer(s)." } }

    def stub_find(result)
      captured = nil
      allow(Portage::Cli::Find).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Find, call: result)
      }
      -> { captured }
    end

    it "requires a query" do
      expect { expect(described_class.run(["find"])).to eq(1) }.to output.to_stderr
    end

    it "prints the ranked offers and exits 0" do
      stub_find(found)

      output = capture_stdout { expect(described_class.run(["find", "--query", "cold"])).to eq(0) }

      expect(output).to include("Found 1 offer(s).", "https://shop.example", "Cold Brew", "24.00 USD")
    end

    it "marks browse-only offers and unknown prices" do
      stub_find(found.merge(offers: [offer.merge(checkout: false, amount: nil, currency: nil)]))

      output = capture_stdout { described_class.run(["find", "--query", "cold"]) }

      expect(output).to include("price n/a", "browse only")
    end

    it "exits 1 when nothing was found" do
      stub_find(found.merge(offers: []))

      capture_stdout { expect(described_class.run(["find", "--query", "cold"])).to eq(1) }
    end

    it "converts --max-price from major to minor units" do
      captured = stub_find(found)

      capture_stdout { described_class.run(["find", "--query", "cold", "--max-price", "24.50", "--limit", "3"]) }

      expect(captured.call).to include(query: "cold", max_price: 2450, limit: 3)
    end
  end

  describe "buy without a url" do
    let(:offer) do
      { store: "https://shop.example", source: "duckduckgo", checkout: true,
        product_id: "p1", title: "Cold Brew", amount: 2400, currency: "USD", url: nil }
    end
    let(:found) { { query: "cold", candidates: [], stores: [], offers: [offer], message: "Found 1 offer(s)." } }

    before { allow($stdin).to receive(:tty?).and_return(false) }

    def stub_buy
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }
      -> { captured }
    end

    it "buys directly from --store without searching at all" do
      captured = stub_buy
      allow(Portage::Cli::Find).to receive(:new)

      capture_stdout { described_class.run(["buy", "--query", "cold", "--store", "https://shop.example", "--yes"]) }

      expect(captured.call).to include(url: "https://shop.example", query: "cold", yes: true)
      expect(Portage::Cli::Find).not_to have_received(:new)
    end

    it "lists offers but refuses to buy when the run isn't interactive" do
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      allow(Portage::Cli::Buy).to receive(:new)

      output = capture_stdout { expect(described_class.run(["buy", "--query", "cold", "--yes"])).to eq(0) }

      expect(output).to include("Cold Brew")
      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "buys the picked offer by product id when a human picks one" do
      allow($stdin).to receive_messages(tty?: true, gets: "1\n")
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      captured = stub_buy

      capture_stdout { described_class.run(["buy", "--query", "cold", "--yes"]) }

      expect(captured.call).to include(url: "https://shop.example", product_id: "p1", query: "cold")
    end

    it "quits without buying on an empty or out-of-range pick" do
      allow($stdin).to receive_messages(tty?: true, gets: "\n")
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      allow(Portage::Cli::Buy).to receive(:new)

      capture_stdout { described_class.run(["buy", "--query", "cold"]) }

      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "still needs a url or a query" do
      expect { expect(described_class.run(["buy", "--yes"])).to eq(1) }.to output.to_stderr
    end

    it "treats a bare positional arg with no --query as the search query, not a store URL" do
      find_query = nil
      allow(Portage::Cli::Find).to receive(:new) { |**opts|
        find_query = opts[:query]
        instance_double(Portage::Cli::Find, call: found)
      }
      allow(Portage::Cli::Buy).to receive(:new)

      capture_stdout { described_class.run(%w[buy coffee]) }

      expect(find_query).to eq("coffee")
      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "still reads a URL-looking bare arg as the store, not the query" do
      captured = stub_buy
      allow(Portage::Cli::Find).to receive(:new)

      capture_stdout { described_class.run(["buy", "shop.example", "--query", "cold", "--yes"]) }

      expect(captured.call).to include(url: "shop.example", query: "cold")
      expect(Portage::Cli::Find).not_to have_received(:new)
    end

    # docs/plans/buy-skill-and-local-browser.md Phase 2b: the local index
    # is untrusted data, so an offer sourced from it must never let --yes
    # alone complete a buy — the same interactive-pick gate a web-search
    # offer gets, not a shortcut.
    it "an index-sourced offer never counts as 'picked a store' for --yes with no tty" do
      indexed_offer = offer.merge(source: "index")
      found_from_index = found.merge(offers: [indexed_offer])
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find,
                                                                            call: found_from_index))
      allow(Portage::Cli::Buy).to receive(:new)

      capture_stdout { expect(described_class.run(["buy", "--query", "cold", "--yes"])).to eq(0) }

      expect(Portage::Cli::Buy).not_to have_received(:new)
    end
  end

  describe "buy --offer and quotes" do
    let(:dry_run) do
      report.merge(outcome: "dry_run", checkout_id: "chk_1", checkout_status: "ready_for_complete", currency: "USD",
                   totals: [{ "type" => "total", "amount" => 2400 }],
                   items: [{ id: "v1", title: "Cold Brew", quantity: 1 }])
    end
    let(:purchased) { dry_run.merge(outcome: "purchased") }
    let(:quotes) { Portage::Cli::Quotes.new }

    # Each Buy.new gets the next report; every option set is recorded.
    def stub_buys(*reports)
      calls = []
      queue = reports.dup
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        calls << opts
        instance_double(Portage::Cli::Buy, call: queue.shift || reports.last)
      }
      calls
    end

    def json_of(&)
      JSON.parse(capture_stdout(&), symbolize_names: true)
    end

    def saved_quote(**fields)
      quotes.create(store: "https://shop.example", product_id: "p1", qty: 2, total: 2400, currency: "USD",
                    query: "cold", **fields)
    end

    describe "--offer" do
      let(:history) do
        instance_double(Portage::Cli::History, record_search: nil, record_purchase: nil).tap do |h|
          allow(Portage::Cli::History).to receive(:new).and_return(h)
          allow(h).to receive(:offer).with("of_aaaaaa")
                                     .and_return("offer_ref" => "of_aaaaaa", "store" => "https://shop.example",
                                                 "product_id" => "p1", "query" => "cold")
          allow(h).to receive(:offer).with("of_nope").and_return(nil)
        end
      end

      it "buys the saved offer's store and product, as if they'd been passed as flags" do
        history
        calls = stub_buys(dry_run)

        capture_stdout { described_class.run(%w[buy --offer of_aaaaaa --dry-run]) }

        expect(calls.first).to include(url: "https://shop.example", product_id: "p1", query: "cold",
                                       dry_run: true)
      end

      it "reports an unknown ref as an offer_not_found outcome and buys nothing" do
        history
        calls = stub_buys(dry_run)

        out = json_of { expect(described_class.run(%w[buy --offer of_nope --json])).to eq(1) }

        expect(out).to include(outcome: "offer_not_found", browse: false, checkout: false)
        expect(out[:message]).to include("of_nope")
        expect(calls).to be_empty
      end
    end

    describe "a --dry-run" do
      it "saves a quote and reports its quote_id" do
        history = instance_double(Portage::Cli::History, record_search: nil, record_purchase: nil)
        allow(Portage::Cli::History).to receive(:new).and_return(history)
        allow(history).to receive(:offer).and_return("offer_ref" => "of_aaaaaa", "store" => "https://shop.example",
                                                     "product_id" => "p1", "query" => "cold")
        stub_buys(dry_run)

        out = json_of { described_class.run(%w[buy --offer of_aaaaaa --qty 2 --dry-run --json]) }

        expect(out[:quote_id]).to match(/\Aqt_[0-9a-f]{12}\z/)
        expect(quotes.find(out[:quote_id])).to include(
          "offer_ref" => "of_aaaaaa", "store" => "https://shop.example", "product_id" => "p1", "qty" => 2,
          "total" => 2400, "currency" => "USD", "approved" => false
        )
      end

      it "saves a quote without an offer_ref for a plain url buy" do
        stub_buys(dry_run)

        out = json_of { described_class.run(%w[buy shop.example --query cold --dry-run --json]) }

        expect(quotes.find(out[:quote_id])).to include("offer_ref" => nil, "query" => "cold", "qty" => 1)
      end

      it "prints the quote in plain output too" do
        stub_buys(dry_run)

        text = capture_stdout { described_class.run(%w[buy shop.example --query cold --dry-run]) }

        expect(text).to match(/quote: qt_[0-9a-f]{12}/)
      end

      it "saves no quote for a run that isn't a dry run" do
        stub_buys(dry_run.merge(outcome: "needs_confirmation"))

        out = json_of { described_class.run(%w[buy shop.example --query cold --json]) }

        expect(out).not_to have_key(:quote_id)
      end
    end

    describe "--quote" do
      it "refuses an unknown quote with a quote_not_found outcome" do
        calls = stub_buys(purchased)

        out = json_of { expect(described_class.run(%w[buy --quote qt_000000000000 --yes --json])).to eq(1) }

        expect(out).to include(outcome: "quote_not_found")
        expect(calls).to be_empty
      end

      it "hands Buy the quoted total and currency as its cap, and reports what it buys" do
        quote = saved_quote
        calls = stub_buys(purchased)

        out = json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"]) }

        expect(out[:outcome]).to eq("purchased")
        expect(calls.length).to eq(1)
        expect(calls.first).to include(url: "https://shop.example", product_id: "p1", query: "cold", qty: 2,
                                       yes: true, quote_total: 2400, quote_currency: "USD")
      end

      it "reports Buy's quote_changed refusal with the quote_id, and leaves the quote unspent" do
        quote = saved_quote(total: 2000)
        stub_buys(report.merge(outcome: "quote_changed", browse: true, checkout: true, quoted_total: 2000,
                               current_total: 2400, handoff: nil))

        out = json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"]) }

        expect(out).to include(outcome: "quote_changed", quote_id: quote["quote_id"], quoted_total: 2000,
                               current_total: 2400)
        expect(quotes.find(quote["quote_id"])).not_to have_key("used_at")
      end

      it "spends the quote on a purchase, and refuses a second run with quote_used" do
        quote = saved_quote
        calls = stub_buys(purchased)

        json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"]) }
        out = json_of { expect(described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"])).to eq(1) }

        expect(quotes.find(quote["quote_id"])).to include("used_at")
        expect(out).to include(outcome: "quote_used")
        expect(calls.length).to eq(1)
      end

      it "spends the quote on a hand-off outcome too" do
        quote = saved_quote
        stub_buys(dry_run.merge(outcome: "policy_blocked", handoff: { opened: true, notified: false }))

        json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"]) }

        expect(quotes.find(quote["quote_id"])).to include("used_at")
      end

      it "leaves the quote usable after an outcome that neither bought nor handed off" do
        quote = saved_quote
        stub_buys(dry_run.merge(outcome: "no_payment_token"))

        json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--yes", "--json"]) }

        expect(quotes.find(quote["quote_id"])).not_to have_key("used_at")
      end

      it "doesn't reprice or spend the quote without --yes" do
        quote = saved_quote
        calls = stub_buys(dry_run.merge(outcome: "needs_confirmation"))

        out = json_of { described_class.run(["buy", "--quote", quote["quote_id"], "--json"]) }

        expect(out[:outcome]).to eq("needs_confirmation")
        expect(calls.length).to eq(1)
        expect(quotes.find(quote["quote_id"])).not_to have_key("used_at")
      end
    end
  end

  describe "history" do
    def stub_history
      instance_double(Portage::Cli::History).tap do |h|
        allow(Portage::Cli::History).to receive(:new).and_return(h)
      end
    end

    it "records a search after find runs" do
      allow(Portage::Cli::Find).to receive(:new)
        .and_return(instance_double(Portage::Cli::Find,
                                    call: { query: "cold", candidates: [], stores: [], offers: [],
                                            message: "none" }))
      h = stub_history
      allow(h).to receive(:record_search)

      capture_stdout { described_class.run(["find", "--query", "cold"]) }

      expect(h).to have_received(:record_search).with(query: "cold", offer_count: 0, message: "none", offers: [])
    end

    it "hands the offers, with their refs, to the saved search" do
      offers = [{ offer_ref: "of_aaaaaa", store: "https://shop.example", product_id: "p1", title: "Cold Brew",
                  amount: 2400, currency: "USD" }]
      allow(Portage::Cli::Find).to receive(:new)
        .and_return(instance_double(Portage::Cli::Find,
                                    call: { query: "cold", candidates: [], stores: [], offers: offers,
                                            message: "Found 1 offer(s)." }))
      h = stub_history
      allow(h).to receive(:record_search)

      capture_stdout { described_class.run(["find", "--query", "cold"]) }

      expect(h).to have_received(:record_search).with(hash_including(offers: offers))
    end

    it "records every buy that created a checkout as a purchase, with its outcome and what it holds" do
      h = stub_history
      allow(h).to receive(:record_purchase)
      held = report.merge(outcome: "policy_blocked", checkout_id: "chk_1", checkout_status: "ready_for_complete",
                          checkout_url: "https://shop.example/c/1", currency: "USD",
                          totals: [{ "type" => "total", "amount" => 1200 }],
                          items: [{ id: "v1", title: "Cold Brew", quantity: 1 }])
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: held))

      capture_stdout { described_class.run(["buy", "shop.example", "--query", "cold"]) }

      expect(h).to have_received(:record_purchase).with(
        hash_including(url: "https://shop.example", query: "cold", outcome: "policy_blocked", checkout_id: "chk_1",
                       checkout_url: "https://shop.example/c/1", total: 1200, currency: "USD",
                       items: [{ "id" => "v1", "title" => "Cold Brew", "quantity" => 1 }])
      )
    end

    it "records a buy that never reached a checkout as a search at that store, not a purchase" do
      h = stub_history
      allow(h).to receive(:record_purchase)
      allow(h).to receive(:record_search)
      no_match = report.merge(outcome: "no_match", message: "No product matched \"cold\".")
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: no_match))

      capture_stdout { described_class.run(["buy", "shop.example", "--query", "cold"]) }

      expect(h).not_to have_received(:record_purchase)
      expect(h).to have_received(:record_search).with(query: "cold", url: "https://shop.example", offer_count: 1,
                                                      message: "No product matched \"cold\".")
    end

    it "records the search behind a buy with no url" do
      allow(Portage::Cli::Find).to receive(:new)
        .and_return(instance_double(Portage::Cli::Find, call: { query: "cold", offers: [], message: "none" }))
      h = stub_history
      allow(h).to receive(:record_search)

      capture_stdout { described_class.run(["buy", "--query", "cold"]) }

      expect(h).to have_received(:record_search).with(query: "cold", offer_count: 0, message: "none", offers: [])
    end

    it "lists purchases and searches" do
      h = stub_history
      allow(h).to receive(:purchases).and_return(
        [{ "url" => "https://shop.example", "query" => "cold", "outcome" => "low_confidence",
           "checkout_url" => "https://shop.example/c/1", "total" => 1200, "currency" => "USD",
           "items" => [{ "id" => "v1", "title" => "Cold Brew", "quantity" => 2 }], "at" => 0 },
         { "url" => "https://old.example", "query" => "tea", "checkout_status" => "completed", "at" => 0 }]
      )
      allow(h).to receive(:searches).and_return([{ "query" => "cold", "offer_count" => 1, "at" => 0 }])

      output = capture_stdout { expect(described_class.run(["history"])).to eq(0) }

      expect(output).to include("Purchases:", "Searches:", "\"cold\"")
      expect(output).to include("low_confidence — https://shop.example (cold) — Cold Brew x2 — 12.00 USD — " \
                                "https://shop.example/c/1")
      # An entry recorded before `outcome` existed still lists.
      expect(output).to include("completed — https://old.example (tea)")
    end

    it "filters to just purchases or searches" do
      h = stub_history
      allow(h).to receive(:purchases).and_return([])
      allow(h).to receive(:searches).and_return([])

      capture_stdout { described_class.run(["history", "list", "--purchases"]) }

      expect(h).to have_received(:purchases)
      expect(h).not_to have_received(:searches)
    end

    it "clears history, optionally scoped to one kind" do
      h = stub_history
      allow(h).to receive(:clear)

      capture_stdout { described_class.run(["history", "clear", "--searches"]) }

      expect(h).to have_received(:clear).with(kind: "searches")
    end

    it "prints usage for an unknown history subcommand" do
      expect { expect(described_class.run(%w[history nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "policy" do
    around { |example| Dir.mktmpdir { |dir| @policy_path = File.join(dir, "policy.json") and example.run } }

    before { allow(Portage::Ucp::Policy).to receive(:load).and_return(Portage::Ucp::Policy.load(path: @policy_path)) }

    it "reports no policy configured by default" do
      output = capture_stdout { expect(described_class.run(%w[policy show])).to eq(0) }

      expect(output).to include("no policy configured")
    end

    def persisted_policy = JSON.parse(File.read(@policy_path))

    it "sets a per-transaction cap and shows it back" do
      capture_stdout { described_class.run(%w[policy set --per-transaction-cap 5000 --currency USD]) }

      expect(persisted_policy["per_transaction_cap"]).to eq({ "amount" => 5000, "currency" => "USD" })
    end

    it "requires --currency alongside a cap" do
      expect { described_class.run(%w[policy set --per-transaction-cap 5000]) }.to raise_error(ArgumentError)
    end

    it "appends to the merchant allowlist across separate invocations" do
      capture_stdout { described_class.run(%w[policy set --allow shop-a.example.com]) }
      capture_stdout { described_class.run(%w[policy set --allow shop-b.example.com]) }

      expect(persisted_policy["merchant_allowlist"]).to eq(%w[shop-a.example.com shop-b.example.com])
    end

    it "clears the allowlist" do
      capture_stdout { described_class.run(%w[policy set --allow shop-a.example.com]) }
      capture_stdout { described_class.run(%w[policy set --clear-allowlist]) }

      expect(persisted_policy["merchant_allowlist"]).to eq([])
    end

    it "prints usage for an unknown policy subcommand" do
      expect { expect(described_class.run(%w[policy nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "buy --wait (docs/plans/handoff-reconcile.md Phase 3)" do
    let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }
    let(:handoff_report) do
      { url: "https://shop.example", source: "native_ucp", browse: true, checkout: true, checkout_id: "chk_1",
        checkout_url: "https://shop.example/c/chk_1", outcome: "requires_escalation", message: "hand off",
        products: [], warnings: [], handoff: { url: "https://shop.example/c/chk_1", opened: false,
                                               notified: false, notify_error: nil } }
    end

    def reserve_pending
      transaction_log.reserve(idempotency_key: "portage-buy:shop.example:chk_1", checkout_id: "chk_1",
                              payment_token_ref: nil, shop: "shop.example", settled_by: "shopper")
    end

    def stub_buy(report)
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: report))
    end

    it "never passes --wait/--wait-timeout through to Buy.new" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      capture_stdout { described_class.run(%w[buy shop.example --query cold --wait --wait-timeout 5m]) }

      expect(captured).not_to have_key(:wait)
      expect(captured).not_to have_key(:wait_timeout)
    end

    it "does nothing extra when there's no handoff to wait on" do
      stub_buy(report)
      expect(Portage::Cli::HandoffWaiter).not_to receive(:new)

      capture_stdout { described_class.run(%w[buy shop.example --query cold --wait]) }
    end

    it "polls until the handoff settles, then reports it" do
      stub_buy(handoff_report)
      reserve_pending
      settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "portage-buy:shop.example:chk_1",
                                                            settled: true, status: "complete", order_id: "ord_1",
                                                            amount: 4200, currency: "USD")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: settled))

      output = capture_stdout { described_class.run(%w[buy shop.example --query cold --wait]) }

      expect(output).to include("requires_escalation")
    end

    it "streams NDJSON events under --wait --json, ending with the final report object" do
      stub_buy(handoff_report)
      reserve_pending
      settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "portage-buy:shop.example:chk_1",
                                                            settled: true, status: "complete", order_id: "ord_1",
                                                            amount: 4200, currency: "USD")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: settled))

      output = capture_stdout { described_class.run(%w[buy shop.example --query cold --wait --json]) }
      lines = output.lines.map(&:strip).reject(&:empty?)

      first_event = JSON.parse(lines.first)
      expect(first_event).to include("event" => "handoff", "checkout_id" => "chk_1")
      settled_event = JSON.parse(lines[1])
      expect(settled_event).to include("event" => "handoff_settled", "result" => "complete", "order_id" => "ord_1")
      final = JSON.parse(lines[2..].join("\n"))
      expect(final).to include("outcome" => "requires_escalation")
      expect(final["reconcile"]).to include("status" => "complete")
    end

    it "forces the terminal notify channel in plain mode but not under --json" do
      stub_buy(handoff_report)
      reserve_pending
      settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "portage-buy:shop.example:chk_1",
                                                            settled: true, status: "complete")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: settled))

      captured_channels = nil
      allow(Portage::Cli::ReconcileNotify).to receive(:resolve) { |**kwargs| captured_channels = kwargs[:extra] }

      capture_stdout { described_class.run(%w[buy shop.example --query cold --wait]) }
      expect(captured_channels).to eq(["terminal"])

      capture_stdout { described_class.run(%w[buy shop.example --query cold --wait --json]) }
      expect(captured_channels).to eq([])
    end

    it "passes --wait-timeout through to HandoffWaiter" do
      stub_buy(handoff_report)
      reserve_pending
      settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "portage-buy:shop.example:chk_1",
                                                            settled: true, status: "complete")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: settled))
      captured = nil
      allow(Portage::Cli::HandoffWaiter).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::HandoffWaiter, call: settled)
      }

      capture_stdout { described_class.run(%w[buy shop.example --query cold --wait --wait-timeout 5m]) }

      expect(captured[:wait_timeout_override]).to eq("5m")
    end
  end

  describe "orders reconcile" do
    let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }

    it "reports nothing to reconcile when the log is empty" do
      output = capture_stdout { expect(described_class.run(%w[orders reconcile])).to eq(0) }

      expect(output).to include("nothing to reconcile")
    end

    it "reconciles every pending shopper record" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: nil,
                              settled_by: "shopper")
      result = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: true, status: "failed",
                                                           resolution: "expired")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: result))

      output = capture_stdout { expect(described_class.run(%w[orders reconcile])).to eq(0) }

      expect(output).to include("k1: failed").and include("resolution: expired")
    end

    it "reconciles only the named --checkout" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: nil,
                              settled_by: "shopper")
      transaction_log.reserve(idempotency_key: "k2", checkout_id: "chk_2", payment_token_ref: nil,
                              settled_by: "shopper")
      seen = []
      reconciler = instance_double(Portage::Cli::HandoffReconciler)
      allow(reconciler).to receive(:call) do |record|
        seen << record["checkout_id"]
        Portage::Cli::HandoffReconciler::Result.new(idempotency_key: record["idempotency_key"], settled: false,
                                                    note: "pending")
      end
      allow(Portage::Cli::HandoffReconciler).to receive(:new).and_return(reconciler)

      capture_stdout { described_class.run(%w[orders reconcile --checkout chk_2]) }

      expect(seen).to eq(["chk_2"])
    end

    it "emits JSON under --json" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: nil,
                              settled_by: "shopper")
      result = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, note: "pending")
      allow(Portage::Cli::HandoffReconciler).to receive(:new)
        .and_return(instance_double(Portage::Cli::HandoffReconciler, call: result))

      output = capture_stdout { described_class.run(%w[orders reconcile --json]) }

      expect(JSON.parse(output)).to eq([{ "idempotency_key" => "k1", "settled" => false, "note" => "pending" }])
    end

    it "prints usage for an unknown orders subcommand" do
      expect { expect(described_class.run(%w[orders nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "index (docs/plans/buy-skill-and-local-browser.md Phase 2b)" do
    it "builds the index and prints a summary" do
      builder = instance_double(Portage::Cli::Index::Builder,
                                build: { sources_run: ["stores_file"], candidates: 2, new_origins_checked: ["a"],
                                         verified: ["a"], capped: false, products_added: 1 })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      output = capture_stdout { expect(described_class.run(%w[index build])).to eq(0) }

      expect(output).to include("stores_file").and include("1 verified")
    end

    it "passes --sources and --queries through to the builder" do
      allow(Portage::Cli::Index::Sources).to receive(:by_name).with(["stores_file"]).and_return([:stub])
      captured = nil
      allow(Portage::Cli::Index::Builder).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Index::Builder, build: { sources_run: [], candidates: 0,
                                                               new_origins_checked: [], verified: [], capped: false,
                                                               products_added: 0 })
      }

      Dir.mktmpdir do |dir|
        queries_file = File.join(dir, "queries.txt")
        File.write(queries_file, "hiking boots\ncoffee\n")

        capture_stdout do
          described_class.run(["index", "build", "--sources", "stores_file", "--queries",
                               queries_file])
        end

        expect(captured[:sources]).to eq([:stub])
      end
    end

    it "passes --export through to the builder and reports what was written" do
      builder = instance_double(Portage::Cli::Index::Builder,
                                build: { sources_run: [], candidates: 0, new_origins_checked: [], verified: [],
                                         capped: false, products_added: 0,
                                         exported: { dir: "/tmp/out", stores: 2, products: 3 } })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      output = capture_stdout do
        expect(described_class.run(%w[index build --export /tmp/out])).to eq(0)
      end

      expect(builder).to have_received(:build).with(hash_including(export: "/tmp/out"))
      expect(output).to include("Exported 2 store(s), 3 product(s) to /tmp/out.")
    end

    it "refreshes instead of building fresh when given 'refresh'" do
      builder = instance_double(Portage::Cli::Index::Builder)
      allow(builder).to receive(:refresh).and_return({ sources_run: [], candidates: 0, new_origins_checked: [],
                                                       verified: [], capped: false, products_added: 0 })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      capture_stdout { described_class.run(%w[index refresh]) }

      expect(builder).to have_received(:refresh)
    end

    it "shows stores and products as JSON" do
      allow(Portage::Cli::Index::Store).to receive(:new)
        .and_return(instance_double(Portage::Cli::Index::Store, all: [{ "origin" => "https://a.example" }]))
      allow(Portage::Cli::Index::ProductStore).to receive(:new)
        .and_return(instance_double(Portage::Cli::Index::ProductStore, all: [{ "title" => "Widget" }]))

      output = capture_stdout { expect(described_class.run(%w[index show --json])).to eq(0) }

      expect(JSON.parse(output)).to eq({ "stores" => [{ "origin" => "https://a.example" }],
                                         "products" => [{ "title" => "Widget" }] })
    end

    it "shows only stores with --stores" do
      allow(Portage::Cli::Index::Store).to receive(:new)
        .and_return(instance_double(Portage::Cli::Index::Store, all: [{ "origin" => "https://a.example" }]))
      allow(Portage::Cli::Index::ProductStore).to receive(:new)
        .and_return(instance_double(Portage::Cli::Index::ProductStore, all: [{ "title" => "Widget" }]))

      output = capture_stdout { described_class.run(%w[index show --stores --json]) }

      expect(JSON.parse(output)["products"]).to eq([])
    end

    it "adds a URL to the index" do
      builder = instance_double(Portage::Cli::Index::Builder)
      allow(builder).to receive(:add).with("https://shop.example")
                                     .and_return({ added: true, origin: "https://shop.example", message: "Added." })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      expect(capture_stdout { described_class.run(%w[index add https://shop.example]) }).to include("Added.")
    end

    it "removes a host from the index" do
      builder = instance_double(Portage::Cli::Index::Builder)
      allow(builder).to receive(:remove).with("shop.example").and_return({ removed: true, message: "Removed." })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      expect(capture_stdout { described_class.run(%w[index remove shop.example]) }).to include("Removed.")
    end

    it "lists every source, name/description/path" do
      output = capture_stdout { expect(described_class.run(%w[index sources])).to eq(0) }

      expect(output).to include("shopify_catalog").and include("stores_file").and include("wikidata")
    end

    it "prints usage for an unknown index subcommand" do
      expect { expect(described_class.run(%w[index nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "browser import (docs/plans/buy-skill-and-local-browser.md Phase 3)" do
    let(:plan) do
      { browser: "chrome", profiles: 1, files_opened: ["/x/Default/History"], rows: { history: 3, bookmark: 1 },
        domains: 3, skipped: { "webmail" => 1 }, already_indexed: 0, known: 0, probed: 2, cached_miss: 0,
        not_ucp: 1, unprobed: 0, capped: false, products: [],
        kept: [{ domain: "shop.example", origin: "https://shop.example", verdict: "ucp", sources: ["history"],
                 visits: 3, categories: { "187" => 3 }, category_names: ["Apparel & Accessories > Shoes"],
                 capabilities: ["catalog"] }] }
    end
    let(:importer) { instance_double(Portage::Cli::BrowserImport::Importer, plan: plan, save: { stores: 1, products: 0 }) }

    before do
      allow(Portage::Cli::BrowserImport::Importer).to receive(:new).and_return(importer)
      allow($stdin).to receive(:tty?).and_return(false)
      # Never look for a real browser profile under the developer's home.
      allow(Portage::Cli::BrowserImport::Profiles).to receive_messages(detect: "chrome", default_root: "/nonexistent")
    end

    def run_json(*args)
      output = capture_stdout { @status = described_class.run(["browser", "import", *args, "--json"]) }
      JSON.parse(output)
    end

    it "wires the real HandoffOnly list into Importer's handoff_only_hosts: seam" do
      Portage::Cli::Config.load.set("handoff_only_hosts", ["shop.example"])

      capture_stdout { described_class.run(%w[browser import --dry-run]) }

      expect(Portage::Cli::BrowserImport::Importer).to have_received(:new).with(handoff_only_hosts: ["shop.example"])
    end

    it "never saves on --dry-run" do
      result = run_json("--dry-run", "--yes")

      expect(@status).to eq(0)
      expect(result).to include("saved" => false, "needs_confirmation" => false,
                                "message" => "Dry run — nothing saved.")
      expect(importer).not_to have_received(:save)
    end

    it "never saves under --json without --yes — it asks the caller to confirm instead" do
      result = run_json

      expect(@status).to eq(0)
      expect(result).to include("saved" => false, "needs_confirmation" => true)
      expect(result["message"]).to include("--yes")
      expect(result["kept"].first).to include("domain" => "shop.example",
                                              "category_names" => ["Apparel & Accessories > Shoes"])
      expect(importer).not_to have_received(:save)
    end

    it "saves on an explicit --yes" do
      result = run_json("--yes")

      expect(result).to include("saved" => true, "message" => "Saved 1 store(s) and 0 product(s) to your local index.")
      expect(importer).to have_received(:save).with(plan)
    end

    it "shows the list, then asks at a TTY and saves only on 'y'" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("y\n")

      output = capture_stdout { expect(described_class.run(%w[browser import])).to eq(0) }

      expect(output).to include("shop.example — ucp — Apparel & Accessories > Shoes (history, 3 visit(s))",
                                "Skipped 1 webmail", "Save these 1 store(s)", "Saved 1 store(s)")
      expect(importer).to have_received(:save)
    end

    it "shows the list but saves nothing with no TTY and no --yes" do
      output = capture_stdout { described_class.run(%w[browser import]) }

      expect(output).to include("shop.example", "Nothing saved")
      expect(importer).not_to have_received(:save)
    end

    it "passes the browser, profile root and caps through" do
      capture_stdout do
        described_class.run(%w[browser import --browser firefox --profile-root /tmp/ff --history-days 30
                               --max-probes 10 --include-product-pages --exclude a.example,b.example --dry-run])
      end

      expect(importer).to have_received(:plan).with(
        having_attributes(browser: "firefox", root: "/tmp/ff", history_days: 30, max_probes: 10,
                          include_product_pages: true, exclude: %w[a.example b.example])
      )
    end

    it "reports a read error (e.g. Safari without Full Disk Access) and exits 1 without saving" do
      allow(importer).to receive(:plan).and_return({ browser: "safari", error: "full_disk_access_required",
                                                     message: "Full Disk Access needed." })

      result = run_json("--browser", "safari", "--yes")

      expect(@status).to eq(1)
      expect(result).to include("error" => "full_disk_access_required", "saved" => false)
      expect(importer).not_to have_received(:save)
    end

    it "rejects an unknown --browser" do
      expect { expect(described_class.run(%w[browser import --browser netscape])).to eq(1) }.to output.to_stderr
    end

    it "prints usage for an unknown browser subcommand" do
      expect { expect(described_class.run(%w[browser nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "browser profile (docs/plans/buy-skill-and-local-browser.md Phase 6)" do
    let(:profile) { instance_double(Portage::Cli::BrowserProfile::Profile, port: 9223, dir: "/x/chrome/profile") }

    before { allow(Portage::Cli::BrowserProfile::Profile).to receive(:new).and_return(profile) }

    def run_json(*args)
      output = capture_stdout { @status = described_class.run(["browser", "profile", *args, "--json"]) }
      JSON.parse(output)
    end

    it "init creates the dedicated profile directory" do
      allow(profile).to receive(:init!).and_return(browser: "chrome", dir: "/x/chrome/profile", port: 9223,
                                                   created: true)

      result = run_json("init")

      expect(@status).to eq(0)
      expect(result).to include("created" => true, "dir" => "/x/chrome/profile")
    end

    it "open launches (or attaches to) the profile and reports the target" do
      allow(profile).to receive(:open!).with(url: "https://shop.example").and_return(
        running: true, browser: "chrome", dir: "/x/chrome/profile", port: 9223, target: { "id" => "1" }
      )

      result = run_json("open", "--url", "https://shop.example")

      expect(@status).to eq(0)
      expect(result).to include("running" => true, "target" => { "id" => "1" })
    end

    it "open reports a browser-not-found error rather than raising" do
      allow(profile).to receive(:open!).and_raise(Portage::Cli::BrowserProfile::BrowserNotFoundError,
                                                  "chrome isn't installed on this machine")

      result = run_json("open")

      expect(@status).to eq(1)
      expect(result).to include("error" => "BrowserNotFoundError",
                                "message" => "chrome isn't installed on this machine")
    end

    it "status reports not running when the profile has no CDP endpoint up" do
      allow(profile).to receive(:status).and_return(running: false, browser: "chrome", dir: "/x/chrome/profile",
                                                    port: 9223)

      result = run_json("status")

      expect(@status).to eq(0)
      expect(result).to include("running" => false)
    end

    it "passes --browser and --port through to the Profile it builds" do
      allow(profile).to receive(:status).and_return(running: false)

      capture_stdout { described_class.run(%w[browser profile status --browser brave --port 9333]) }

      expect(Portage::Cli::BrowserProfile::Profile).to have_received(:new).with(browser: "brave", port: 9333)
    end

    it "prints usage for an unknown browser profile subcommand" do
      expect { expect(described_class.run(%w[browser profile nope])).to eq(1) }.to output.to_stderr
    end
  end

  describe "portage buy --handoff-target profile attaches a browser profile bridge " \
           "(docs/plans/buy-skill-and-local-browser.md Phase 6)" do
    let(:captured) { {} }

    before do
      allow(Portage::Cli::Buy).to receive(:new) do |**opts|
        captured.replace(opts)
        instance_double(Portage::Cli::Buy, call: report)
      end
    end

    it "never attaches a bridge for any target but profile" do
      expect(Portage::Cli).not_to receive(:profile_webmcp_bridge)

      capture_stdout { described_class.run(%w[buy shop.example --query cold --dry-run]) }

      expect(captured[:webmcp_bridge]).to be_nil
    end

    it "attaches nothing when portage-ucp-webmcp isn't available" do
      allow(Portage::Cli::Webmcp).to receive(:available?).and_return(false)

      capture_stdout do
        described_class.run(%w[buy shop.example --query cold --dry-run --handoff-target profile])
      end

      expect(captured[:webmcp_bridge]).to be_nil
    end

    it "attaches nothing when the profile isn't running" do
      allow(Portage::Cli::Webmcp).to receive(:available?).and_return(true)
      not_running = instance_double(Portage::Cli::BrowserProfile::Profile, status: { running: false })
      allow(Portage::Cli::BrowserProfile::Profile).to receive(:new).and_return(not_running)

      capture_stdout do
        described_class.run(%w[buy shop.example --query cold --dry-run --handoff-target profile])
      end

      expect(captured[:webmcp_bridge]).to be_nil
    end

    it "opens a new tab and attaches a CdpSocket-backed bridge when the profile is running" do
      allow(Portage::Cli::Webmcp).to receive(:available?).and_return(true)
      running = instance_double(Portage::Cli::BrowserProfile::Profile, status: { running: true }, port: 9223)
      allow(Portage::Cli::BrowserProfile::Profile).to receive(:new).and_return(running)
      allow(Portage::Cli::BrowserProfile::Cdp).to receive(:list).with(port: 9223).and_return([])
      allow(Portage::Cli::BrowserProfile::Cdp).to receive(:new_tab).with(port: 9223, url: "https://shop.example")
                                                                   .and_return("webSocketDebuggerUrl" => "ws://x")
      socket = instance_double(Portage::Cli::BrowserProfile::CdpSocket)
      allow(Portage::Cli::BrowserProfile::CdpSocket).to receive(:connect).with("ws://x").and_return(socket)

      capture_stdout do
        described_class.run(%w[buy shop.example --query cold --dry-run --handoff-target profile])
      end

      expect(captured[:webmcp_bridge]).to be_a(Portage::Cli::BrowserProfile::Bridge)
    end

    it "reuses an existing tab already on the store's host instead of opening a new one" do
      allow(Portage::Cli::Webmcp).to receive(:available?).and_return(true)
      running = instance_double(Portage::Cli::BrowserProfile::Profile, status: { running: true }, port: 9223)
      allow(Portage::Cli::BrowserProfile::Profile).to receive(:new).and_return(running)
      allow(Portage::Cli::BrowserProfile::Cdp).to receive(:list).with(port: 9223).and_return(
        [{ "type" => "page", "url" => "https://shop.example/cart", "webSocketDebuggerUrl" => "ws://existing" }]
      )
      allow(Portage::Cli::BrowserProfile::Cdp).to receive(:new_tab)
      socket = instance_double(Portage::Cli::BrowserProfile::CdpSocket)
      allow(Portage::Cli::BrowserProfile::CdpSocket).to receive(:connect).with("ws://existing").and_return(socket)

      capture_stdout do
        described_class.run(%w[buy shop.example --query cold --dry-run --handoff-target profile])
      end

      expect(captured[:webmcp_bridge]).to be_a(Portage::Cli::BrowserProfile::Bridge)
      expect(Portage::Cli::BrowserProfile::Cdp).not_to have_received(:new_tab)
    end
  end

  describe "browser import, end to end against a fixture profile" do
    include BrowserImportFixtures

    before do
      skip "sqlite3 CLI not installed" unless sqlite_available?
      allow($stdin).to receive(:tty?).and_return(false)
      session = instance_double(Portage::Ucp::Client::Session, capabilities: %w[dev.ucp.shopping.catalog])
      allow(Portage::Ucp::Client).to receive(:discover) do |origin, **|
        raise Portage::Ucp::Client::DiscoveryError, "404" unless origin == "https://www.shop.example"

        session
      end
    end

    it "writes approved domains as untrusted index entries that find reaches only as source: index" do
      Dir.mktmpdir do |root|
        chrome_profile(root, visits: [{ url: "https://www.shop.example/products/knife", title: "Kitchen Knives",
                                        visits: 4 },
                                      { url: "https://news.example/story", title: "News", visits: 9 },
                                      { url: "https://mail.google.com/mail/u/0", title: "Inbox" }])

        capture_stdout do
          described_class.run(["browser", "import", "--browser", "chrome", "--profile-root", root, "--yes", "--json"])
        end
      end

      entry = Portage::Cli::Index::Store.new.find("https://www.shop.example")
      expect(entry).to include("sources" => ["history"], "capabilities" => ["catalog"], "handoff_only" => false)
      expect(Portage::Cli::Index::Store.new.all.map { |e| e["origin"] }).to eq(["https://www.shop.example"])
      expect(Portage::Cli::SearchBackends::Index.new.search("kitchen knives from shop")).to eq(["https://www.shop.example"])
    end
  end

  describe "doctor output" do
    let(:findings) do
      finding = Portage::Cli::Doctor::Finding
      [finding.new(check: "install", message: "homebrew (/opt/homebrew/Cellar/portage/0.7.4)", level: "info",
                   details: { method: "homebrew", path: "/opt/homebrew/Cellar/portage/0.7.4",
                              prefix: "/opt/homebrew" }),
       finding.new(check: "runtime", message: "Ruby 4.0.7", level: "info",
                   details: { ruby_version: "4.0.7", ruby_path: "/opt/homebrew/opt/ruby/bin/ruby",
                              portage_cli_version: Portage::Cli::VERSION }),
       finding.new(check: "adapters", message: "shopify 0.5.1", level: "info",
                   details: { adapters: [{ name: "portage-ucp-shopify", installed: true, loadable: true,
                                           version: "0.5.1" }] }),
       finding.new(check: "path", message: "shadowed", level: "warning",
                   details: { first: "/mise/bin/portage", candidates: [] })]
    end

    def run_doctor(argv, result)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(instance_double(Portage::Cli::Doctor, call: result))
      code = nil
      output = capture_stdout { code = described_class.run(argv) }
      [code, output]
    end

    it "includes install method, runtime, adapters and PATH data in --json" do
      code, output = run_doctor(%w[doctor --json], findings)

      parsed = JSON.parse(output)
      expect(code).to eq(1)
      expect(parsed).to be_an(Array)
      by_check = parsed.to_h { |f| [f["check"], f] }
      expect(by_check["install"]).to include("level" => "info",
                                             "details" => include("method" => "homebrew", "prefix" => "/opt/homebrew"))
      expect(by_check["runtime"]["details"]).to include("ruby_version" => "4.0.7",
                                                        "portage_cli_version" => Portage::Cli::VERSION)
      expect(by_check["adapters"]["details"]["adapters"].first).to include("name" => "portage-ucp-shopify",
                                                                           "version" => "0.5.1")
      expect(by_check["path"]).to include("level" => "warning", "details" => include("first" => "/mise/bin/portage"))
    end

    it "exits 0 when every finding is info, printing the report above 'No issues found.'" do
      code, output = run_doctor(%w[doctor], findings.first(3))

      expect(code).to eq(0)
      expect(output).to eq("[install] homebrew (/opt/homebrew/Cellar/portage/0.7.4)\n[runtime] Ruby 4.0.7\n" \
                           "[adapters] shopify 0.5.1\n\nNo issues found.\n")
    end
  end

  describe "doctor seller checks" do
    def doctor_kwargs(argv)
      captured = nil
      allow(Portage::Cli::Doctor).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Doctor, call: [])
      }
      capture_stdout { described_class.run(argv) }
      captured
    end

    it "skips them in a bare shopper run" do
      expect(doctor_kwargs(%w[doctor])).to include(seller: false)
    end

    it "runs them once --adapter names a seller's adapter" do
      expect(doctor_kwargs(%w[doctor --adapter Portage::Ucp::Adapter])).to include(seller: true)
    end
  end

  describe "configure/setup aliases" do
    %w[configure setup].each do |alias_name|
      it "routes #{alias_name} to the same command as doctor" do
        captured = nil
        allow(Portage::Cli::Doctor).to receive(:new) { |**opts|
          captured = opts
          instance_double(Portage::Cli::Doctor, call: [])
        }

        capture_stdout { described_class.run([alias_name, "--adapter", "Portage::Ucp::Adapter"]) }

        expect(captured).to include(adapter_class: Portage::Ucp::Adapter)
      end
    end
  end

  describe "setup wizard (docs/plans/buy-skill-and-local-browser.md Phase 4)" do
    def doctor_double(nothing_configured:)
      instance_double(Portage::Cli::Doctor, call: [], nothing_configured?: nothing_configured)
    end

    it "`doctor --json` stays exactly today's report even on a TTY with nothing configured" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: true))
      expect(Portage::Cli::SetupWizard).not_to receive(:new)

      code = nil
      output = capture_stdout { code = described_class.run(%w[doctor --json]) }

      expect(code).to eq(0)
      expect(JSON.parse(output)).to eq([])
    end

    it "a piped/no-TTY `doctor` stays exactly today's report, even with nothing configured" do
      allow($stdin).to receive(:tty?).and_return(false)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: true))
      expect(Portage::Cli::SetupWizard).not_to receive(:new)

      described_class.run(%w[doctor])
    end

    it "a bare `doctor` on a TTY stays the report when something's already configured" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: false))
      expect(Portage::Cli::SetupWizard).not_to receive(:new)

      capture_stdout { described_class.run(%w[doctor]) }
    end

    it "a bare `doctor` on a TTY offers the wizard when nothing at all is configured" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: true))
      wizard = instance_double(Portage::Cli::SetupWizard, call: 0)
      expect(Portage::Cli::SetupWizard).to receive(:new).and_return(wizard)

      expect(described_class.run(%w[doctor])).to eq(0)
    end

    it "`portage setup` on a TTY always offers the wizard, whatever's already configured" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: false))
      wizard = instance_double(Portage::Cli::SetupWizard, call: 0)
      expect(Portage::Cli::SetupWizard).to receive(:new).and_return(wizard)

      expect(described_class.run(%w[setup])).to eq(0)
    end

    it "`portage setup --json` stays today's doctor report, not the wizard" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: true))
      expect(Portage::Cli::SetupWizard).not_to receive(:new)

      capture_stdout { described_class.run(%w[setup --json]) }
    end

    it "`portage setup` with no TTY on stdin stays today's doctor report" do
      allow($stdin).to receive(:tty?).and_return(false)
      allow(Portage::Cli::Doctor).to receive(:new).and_return(doctor_double(nothing_configured: true))
      expect(Portage::Cli::SetupWizard).not_to receive(:new)

      capture_stdout { described_class.run(%w[setup]) }
    end
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

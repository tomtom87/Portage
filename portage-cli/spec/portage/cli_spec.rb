require "spec_helper"
require "tmpdir"

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

    it "prints JSON when --json is given, and strips :json before building Buy" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      output = nil
      expect { output = capture_stdout { described_class.run(%w[buy shop.example --json]) } }.not_to raise_error

      expect(captured).not_to have_key(:json)
      expect(JSON.parse(output)["source"]).to eq("native_ucp")
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

      expect(h).to have_received(:record_search).with(query: "cold", offer_count: 0, message: "none")
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

      expect(h).to have_received(:record_search).with(query: "cold", offer_count: 0, message: "none")
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

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

require "spec_helper"
require "portage/cli/mcp/server"

RSpec.describe Portage::Cli::Mcp::Tools do
  let(:tools) { described_class::TOOLS }
  let(:runner) { instance_double(Portage::Cli::Mcp::Runner) }
  let(:spawned) { [] }

  before do
    allow(runner).to receive(:response) { |argv| spawned << argv and MCP::Tool::Response.new([]) }
    allow(runner).to receive(:sections) { |argv| spawned << argv and MCP::Tool::Response.new([]) }
  end

  # Through the real tool class Server builds, as tools/call would.
  def call(name, params)
    Portage::Cli::Mcp::Server.build_tool(name, tools.fetch(name), runner).call(**params)
  end

  def argv_for(name, params)
    tools.fetch(name)[:argv].call(params.dup)
  rescue described_class::InputError
    nil
  end

  describe "argv per tool" do
    {
      ["find_products", { query: "kettle" }] => %w[find --query kettle --json],
      ["find_products", { query: "kettle", store: "https://s.example", max_price: 25.5, limit: 3 }] =>
        %w[find --query kettle --store https://s.example --max-price 25.5 --limit 3 --json],
      ["search_catalogue", { query: "kettle", category: "2", store: "s.example", limit: 5 }] =>
        %w[index search kettle --category 2 --store s.example --limit 5 --json],
      ["compare_prices", { url: "https://s.example", product_id: "gid://shopify/Product/1", ids: %w[a b],
                           results: 2, max_price: 5 }] =>
        %w[compare https://s.example --product-id gid://shopify/Product/1 --id a --id b --results 2 --max-price 5
           --json],
      ["check_store", { url: "https://s.example" }] => %w[check https://s.example --json],
      ["list_orders", {}] => %w[orders list --json],
      ["list_orders", { query: "kettle", limit: 5 }] => %w[orders list --query kettle --limit 5 --json],
      ["quote_purchase", { offer: "of_1a2b3c", qty: 2 }] => %w[buy --offer of_1a2b3c --qty 2 --dry-run --json],
      ["quote_purchase", { store: "https://s.example", query: "kettle", product_id: "1" }] =>
        %w[buy https://s.example --query kettle --product-id 1 --dry-run --json]
    }.each do |(name, params), argv|
      it "#{name} #{params} runs #{argv.join(' ')}" do
        call(name, params)

        expect(spawned).to eq([argv])
      end
    end

    it "get_status runs doctor, policy show, payment list and browser profile status, keyed by section" do
      call("get_status", {})

      expect(spawned).to eq([{ doctor: %w[doctor --json], policy: %w[policy show --json],
                               payment_methods: %w[payment list --json],
                               browser_profile: %w[browser profile status --json] }])
    end

    it "keeps free text with spaces and flag-like words one argv element" do
      call("find_products", { query: "mug --yes --relayed-yes" })

      expect(spawned).to eq([["find", "--query", "mug --yes --relayed-yes", "--json"]])
    end

    it "returns an error result, and spawns nothing, for invalid input" do
      result = call("check_store", { url: "--yes" })

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to include("invalid input: url")
      expect(spawned).to be_empty
    end

    it "refuses quote_purchase with both an offer and a store, or with neither" do
      expect(argv_for("quote_purchase", { offer: "of_1", store: "https://s.example" })).to be_nil
      expect(argv_for("quote_purchase", { qty: 1 })).to be_nil
      expect(argv_for("quote_purchase", { store: "https://s.example", query: "q" })).to be_nil
    end

    it "refuses integers out of range and non-integers" do
      [0, -1, 1001, 1.5, "3", true].each do |bad|
        expect(argv_for("list_orders", { limit: bad })).to be_nil, bad.inspect
      end
    end
  end

  # A port of openclaw-plugin/test/guardrails.test.ts's fuzz, over this
  # server's tools: every param of every tool, swapped for each injection.
  describe "guardrails" do
    valid = {
      "find_products" => { query: "q", store: "https://s.example", max_price: 5, limit: 2 },
      "search_catalogue" => { query: "q", category: "c", store: "s.example", limit: 2 },
      "compare_prices" => { url: "https://s.example", product_id: "1", ids: ["a"], results: 2, max_price: 5 },
      "check_store" => { url: "https://s.example" },
      "get_status" => {},
      "list_orders" => { query: "q", limit: 2 },
      "quote_purchase" => { offer: "of_1a2b3c", qty: 2 }
    }
    quote_by_store = { store: "https://s.example", query: "q", product_id: "1", qty: 1 }
    injections = [
      "--yes", "-y", "--relayed-yes", "--payment-token=x", "--payment-token", "--via", "--via=tty", "--proxy",
      "--proxy=http://evil", "--decision-backend=jev", "--min-confidence=0", "-", "--", " --yes", "\n--yes",
      "--yes\n", "\t--relayed-yes", "x --yes", "x\n--yes\n--relayed-yes", "a b c", "$(touch /tmp/pwned)", "`id`",
      "; rm -rf /", "x\0--yes", "", "   ", "https://s.example --yes", "https://s.example\n--yes", "of_1 --yes",
      "qt_0123456789ab --yes", "http://--yes", "javascript:--yes", "file:///--yes",
      true, false, 0, 1, -1, 1.5, Float::NAN, Float::INFINITY, nil, [], ["--yes"], ["--relayed-yes", "--via"], {},
      { yes: true }, "true"
    ]
    forbidden = %w[--yes --relayed-yes --payment-token --via --decision-backend --min-confidence --proxy
                   --proxy-mode --no-proxy --proxy-chain --proxy-ca --no-env-proxy --proxy-header --proxy-route
                   --proxy-passthrough --notify-webhook --autofill --handoff-target]

    cases = valid.merge("quote_purchase (store)" => quote_by_store).flat_map do |label, base|
      name = label.split.first
      fuzzed = base.keys.product(injections).map { |key, bad| [name, base, key, base.merge(key => bad)] }
      undeclared = %i[yes relayed_yes payment_token via proxy confirm handoff_target]
                   .product(["--yes", true]).map { |k, v| [name, base, nil, base.merge(k => v)] }
      [[name, base, nil, base], [name, base, nil, {}], *fuzzed, *undeclared]
    end

    it "fuzzes all 7 tools with plenty of accepted and rejected inputs" do
      built = cases.map { |name, _, _, params| argv_for(name, params) }

      expect(cases.map(&:first).uniq.size).to eq(7)
      expect(built.compact.size).to be > 50
      expect(built.count(&:nil?)).to be > 200
    end

    it "never emits --yes, a forbidden flag or an unexpected subcommand, whatever the input" do
      cases.each do |name, _, _, params|
        argv = argv_for(name, params)
        next unless argv

        Array(argv.is_a?(Hash) ? argv.values : [argv]).each do |a|
          where = { name: name, params: params, argv: a }.inspect
          expect(a.any? { |e| forbidden.any? { |f| e == f || e.start_with?("#{f}=") } }).to be(false), where
          expect(%w[find index compare check orders buy doctor policy payment browser]).to include(a.first), where
          expect(a.join(" ")).not_to match(/\A(policy set|payment (enroll|remove|revoke|freeze|set-default))/), where
          expect(a).to include("--dry-run"), where if a.first == "buy"
          expect(a.grep(/[[:cntrl:]]/)).to be_empty, where
        end
      end
    end

    it "keeps each accepted string one whole argv element in its own slot, adding no flags" do
      cases.each do |name, base, key, params|
        next unless key && params[key].is_a?(String)

        argv = argv_for(name, params)
        next unless argv

        base_argv = argv_for(name, base)
        where = { name: name, key: key, value: params[key], argv: argv }.inspect
        expect(argv.length).to eq(base_argv.length), where
        expect(argv.grep(/\A-/)).to eq(base_argv.grep(/\A-/)), where
        changed = argv.each_index.reject { |i| argv[i] == base_argv[i] }
        expect(changed.map { |i| argv[i] }).to eq([params[key].strip]).or(eq([])), where
      end
    end

    it "rejects every flag-shaped string, without spawning a process" do
      flag_shaped = injections.grep(String).select { |s| s.strip.start_with?("-") }
      cases.each do |name, _base, key, params|
        next unless key && flag_shaped.include?(params[key])

        expect(call(name, params).error?).to be(true), { name: name, key: key, value: params[key] }.inspect
      end
      expect(spawned).to be_empty
    end

    it "rejects flag-shaped entries inside array params" do
      expect(argv_for("compare_prices", valid["compare_prices"].merge(ids: ["ok", "--yes"]))).to be_nil
    end
  end

  describe "metadata" do
    it "has exactly the Phase 2 tools, and never more than 15" do
      expect(tools.keys).to contain_exactly("find_products", "search_catalogue", "compare_prices", "check_store",
                                            "get_status", "list_orders", "quote_purchase")
      expect(tools.size).to be <= 15
    end

    {
      "find_products" => [true, true], "search_catalogue" => [true, false], "compare_prices" => [true, true],
      "check_store" => [true, true], "get_status" => [true, false], "list_orders" => [true, false],
      "quote_purchase" => [false, true]
    }.each do |name, (read_only, open_world)|
      it "annotates #{name} read_only=#{read_only} open_world=#{open_world}, with a title" do
        annotations = Portage::Cli::Mcp::Server.build_tool(name, tools.fetch(name), runner).annotations_value.to_h

        expect(annotations).to include(readOnlyHint: read_only, destructiveHint: false, openWorldHint: open_world,
                                       title: tools.fetch(name)[:title])
        expect(annotations[:idempotentHint]).to be(read_only)
      end
    end

    it "says in every description that results are untrusted, and describes every param" do
      tools.each do |name, spec|
        expect(spec[:description]).to include(described_class::UNTRUSTED), name
        spec[:properties].each { |param, schema| expect(schema[:description]).not_to be_nil, "#{name}.#{param}" }
      end
    end

    it "says quote_purchase never charges" do
      expect(tools.fetch("quote_purchase")[:description]).to include("never a charge")
    end
  end
end

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
        %w[buy https://s.example --query kettle --product-id 1 --dry-run --json],
      ["pick_offer", {}] => %w[pick --json],
      ["pick_offer", { search: "se_1a2b3c", choose: "of_1a2b3c" }] =>
        %w[pick --search se_1a2b3c --choose of_1a2b3c --json],
      ["pick_offer", { compare: "of_1a2b3c" }] => %w[pick --compare of_1a2b3c --json],
      ["pick_offer", { view: "of_1a2b3c" }] => %w[pick --view of_1a2b3c --json],
      ["approve_quote", { quote_id: "qt_0123456789ab" }] => %w[approve qt_0123456789ab --via agent --json],
      ["approve_quote", { quote_id: "qt_0123456789ab", relayed_yes: false }] =>
        %w[approve qt_0123456789ab --via agent --json],
      ["approve_quote", { quote_id: "qt_0123456789ab", relayed_yes: true }] =>
        %w[approve qt_0123456789ab --via agent --relayed-yes --json],
      ["approve_quote", { quote_id: "qt_0123456789ab", view: true }] =>
        %w[approve qt_0123456789ab --via agent --view --json],
      ["buy_quote", { quote_id: "qt_0123456789ab" }] => %w[buy --quote qt_0123456789ab --yes --json],
      ["hand_off", { offer: "of_1a2b3c" }] => %w[buy --offer of_1a2b3c --json],
      ["hand_off", { offer: "of_1a2b3c", qty: 2, target: "print" }] =>
        %w[buy --offer of_1a2b3c --qty 2 --handoff-target print --json],
      ["hand_off", { store: "https://s.example", query: "kettle", product_id: "1", target: "profile" }] =>
        %w[buy https://s.example --query kettle --product-id 1 --handoff-target profile --json],
      ["reconcile_orders", {}] => %w[orders reconcile --json],
      ["reconcile_orders", { checkout: "co_123" }] => %w[orders reconcile --checkout co_123 --json],
      ["import_browser_history", {}] => %w[browser import --max-probes 15 --dry-run --json],
      ["import_browser_history", { confirm: false }] => %w[browser import --max-probes 15 --dry-run --json],
      ["import_browser_history", { confirm: true }] => %w[browser import --max-probes 15 --yes --json],
      ["import_browser_history", { browser: "safari", history_days: 30, include_product_pages: true,
                                   max_probes: 10, exclude: %w[a.example www.b.example], confirm: true }] =>
        %w[browser import --browser safari --history-days 30 --include-product-pages --max-probes 10
           --exclude a.example,www.b.example --yes --json],
      ["import_browser_history", { include_product_pages: false, exclude: ["a.example"] }] =>
        %w[browser import --max-probes 15 --exclude a.example --dry-run --json],
      ["add_store", { url: "https://s.example" }] => %w[index add https://s.example --json],
      ["add_store", { url: "https://s.example", crawl: false }] => %w[index add https://s.example --json],
      ["add_store", { url: "https://s.example", crawl: true }] => %w[index add https://s.example --crawl --json]
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

    it "refuses hand_off with both an offer and a store, with neither, or with an unknown target" do
      expect(argv_for("hand_off", { offer: "of_1", store: "https://s.example" })).to be_nil
      expect(argv_for("hand_off", { qty: 1 })).to be_nil
      expect(argv_for("hand_off", { offer: "of_1", target: "tty" })).to be_nil
      expect(argv_for("hand_off", { offer: "of_1", target: "agent:x" })).to be_nil
    end

    it "takes at most one of choose, compare and view in pick_offer" do
      expect(argv_for("pick_offer", { choose: "of_1", view: "of_1" })).to be_nil
      expect(argv_for("pick_offer", { compare: "of_1", view: "of_1" })).to be_nil
    end

    it "refuses integers out of range and non-integers" do
      [0, -1, 1001, 1.5, "3", true].each do |bad|
        expect(argv_for("list_orders", { limit: bad })).to be_nil, bad.inspect
      end
    end
  end

  describe "import_browser_history" do
    it "accepts only a strict true as confirm, and never emits both or neither of --dry-run and --yes" do
      ["true", "false", "yes", 1, 0, nil, [], [true], {}].each do |bad|
        expect(argv_for("import_browser_history", { confirm: bad })).to be_nil, bad.inspect
        expect(call("import_browser_history", { confirm: bad }).error?).to be(true), bad.inspect
      end
      [{}, { confirm: false }, { confirm: true }].each do |params|
        argv = argv_for("import_browser_history", params)

        expect((argv & %w[--dry-run --yes]).size).to eq(1)
      end
    end

    it "rejects an unknown or flag-shaped browser" do
      ["netscape", "--yes", "chrome;rm", "Chrome", "", nil, 1].each do |bad|
        expect(argv_for("import_browser_history", { browser: bad })).to be_nil, bad.inspect
      end
      %w[chrome edge brave arc firefox safari].each do |b|
        expect(argv_for("import_browser_history", { browser: b })).to include("--browser", b)
      end
    end

    it "validates each excluded host and joins them into one element" do
      ["https://s.example", "-x", "a b", "a\nb", "a,b", "", nil, 1, "--yes"].each do |bad|
        expect(argv_for("import_browser_history", { exclude: [bad] })).to be_nil, bad.inspect
      end
      expect(argv_for("import_browser_history", { exclude: [] })).to be_nil
      expect(argv_for("import_browser_history", { exclude: "a.example" })).to be_nil
      expect(argv_for("import_browser_history", { exclude: ["a.example", "b.example"] }))
        .to include("--exclude", "a.example,b.example")
    end

    it "bounds max_probes at 15 so a run fits the Runner's 120s timeout" do
      expect(argv_for("import_browser_history", { max_probes: 16 })).to be_nil
      expect(argv_for("import_browser_history", { max_probes: 0 })).to be_nil
      expect(argv_for("import_browser_history", { history_days: "30" })).to be_nil
      expect(argv_for("import_browser_history", { include_product_pages: "true" })).to be_nil
    end
  end

  describe "add_store" do
    it "rejects bad urls and a non-boolean crawl" do
      ["shop.example", "--crawl", "ftp://s.example", "https://s.example\n--crawl", "", nil, 1,
       "javascript:1"].each do |bad|
        expect(argv_for("add_store", { url: bad })).to be_nil, bad.inspect
      end
      ["true", 1, nil, "yes"].each do |bad|
        expect(argv_for("add_store", { url: "https://s.example", crawl: bad })).to be_nil, bad.inspect
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
      "quote_purchase" => { offer: "of_1a2b3c", qty: 2 },
      "pick_offer" => { search: "se_1a2b3c", choose: "of_1a2b3c" },
      "approve_quote" => { quote_id: "qt_0123456789ab", relayed_yes: false, view: false },
      "buy_quote" => { quote_id: "qt_0123456789ab" },
      "hand_off" => { offer: "of_1a2b3c", qty: 2, target: "print" },
      "reconcile_orders" => { checkout: "co_123" },
      "import_browser_history" => { browser: "chrome", history_days: 30, include_product_pages: false,
                                    max_probes: 5, exclude: ["a.example"], confirm: false },
      "add_store" => { url: "https://s.example", crawl: false }
    }
    quote_by_store = { store: "https://s.example", query: "q", product_id: "1", qty: 1 }
    hand_off_by_store = { store: "https://s.example", query: "q", product_id: "1", qty: 1, target: "default" }
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

    variants = { "quote_purchase (store)" => quote_by_store, "hand_off (store)" => hand_off_by_store,
                 "pick_offer (compare)" => { compare: "of_1a2b3c" }, "pick_offer (view)" => { view: "of_1a2b3c" } }
    # The only flags a tool's own argv may carry among `forbidden`.
    allowed_flags = { "approve_quote" => %w[--via --relayed-yes], "buy_quote" => %w[--yes],
                      "import_browser_history" => %w[--yes], "hand_off" => %w[--handoff-target] }
    cases = valid.merge(variants).flat_map do |label, base|
      name = label.split.first
      fuzzed = base.keys.product(injections).map { |key, bad| [name, base, key, base.merge(key => bad)] }
      undeclared = %i[yes relayed_yes payment_token via proxy confirm handoff_target]
                   .product(["--yes", true]).map { |k, v| [name, base, nil, base.merge(k => v)] }
      [[name, base, nil, base], [name, base, nil, {}], *fuzzed, *undeclared]
    end

    it "fuzzes all 14 tools with plenty of accepted and rejected inputs" do
      built = cases.map { |name, _, _, params| argv_for(name, params) }

      expect(cases.map(&:first).uniq.size).to eq(14)
      expect(built.compact.size).to be > 50
      expect(built.count(&:nil?)).to be > 200
    end

    it "never emits --yes, a forbidden flag or an unexpected subcommand, whatever the input" do
      cases.each do |name, _, _, params|
        argv = argv_for(name, params)
        next unless argv

        Array(argv.is_a?(Hash) ? argv.values : [argv]).each do |a|
          where = { name: name, params: params, argv: a }.inspect
          banned = forbidden - (allowed_flags[name] || [])
          expect(a.any? { |e| banned.any? { |f| e == f || e.start_with?("#{f}=") } }).to be(false), where
          expect(%w[find index compare check orders buy pick approve doctor policy payment browser])
            .to include(a.first), where
          expect(a.join(" ")).not_to match(/\A(policy set|payment (enroll|remove|revoke|freeze|set-default)|setup)/),
                                     where
          expect(a).to include("--dry-run"), where if name == "quote_purchase"
          expect(a & %w[--dry-run --quote --yes]).to be_empty, where if name == "hand_off"
          expect(a.grep(/[[:cntrl:]]/)).to be_empty, where
        end
      end
    end

    it "puts --yes only on buy --quote ID or a confirmed import, and --via only as --via agent on approve" do
      cases.each do |name, _, _, params|
        argv = argv_for(name, params) or next
        where = { name: name, params: params, argv: argv }.inspect

        spends = name == "buy_quote" || (name == "import_browser_history" && params[:confirm] == true)
        expect(argv.include?("--yes")).to eq(spends), where
        expect(argv.include?("--dry-run")).to be(!argv.include?("--yes")), where if name == "import_browser_history"
        expect(argv).to eq(["buy", "--quote", params[:quote_id], "--yes", "--json"]), where if name == "buy_quote"
        expect(argv.include?("--via")).to eq(name == "approve_quote"), where
        expect(argv[argv.index("--via") + 1]).to eq("agent"), where if argv.include?("--via")
        expect(argv).not_to include("tty"), where
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

  describe "relayed_yes" do
    let(:quote) { { quote_id: "qt_0123456789ab" } }

    it "is a strict boolean: only true adds --relayed-yes, and the default is false" do
      expect(argv_for("approve_quote", quote)).not_to include("--relayed-yes")
      expect(argv_for("approve_quote", quote.merge(relayed_yes: false))).not_to include("--relayed-yes")
      expect(argv_for("approve_quote", quote.merge(relayed_yes: true))).to include("--relayed-yes")
    end

    it "rejects anything but true or false, spawning nothing" do
      ["true", "false", "yes", "TRUE", 1, 0, 1.0, nil, [], [true], {}, { yes: true }].each do |bad|
        expect(argv_for("approve_quote", quote.merge(relayed_yes: bad))).to be_nil, bad.inspect
        expect(call("approve_quote", quote.merge(relayed_yes: bad)).error?).to be(true), bad.inspect
        expect(argv_for("approve_quote", quote.merge(view: bad))).to be_nil, "view #{bad.inspect}"
      end
      expect(spawned).to be_empty
    end

    it "refuses relayed_yes together with view" do
      expect(argv_for("approve_quote", quote.merge(relayed_yes: true, view: true))).to be_nil
    end

    it "always runs --via agent, whatever the params try to inject" do
      ["tty", "auto", "agent", "--via", "--via=tty"].each do |via|
        argv = argv_for("approve_quote", quote.merge(via: via, surface: via))

        expect(argv).to eq(%w[approve qt_0123456789ab --via agent --json])
      end
    end
  end

  # The real Runner, `portage` subprocess and a temp HOME: a person-level
  # policy turns a relayed yes into needs_approval and records nothing.
  describe "approve_quote under a person-level policy" do
    def with_home(policy)
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, ".portage"))
        File.write(File.join(home, ".portage", "policy.json"), JSON.generate(policy))
        quotes = Portage::Cli::Quotes.new(dir: File.join(home, ".portage", "quotes"))
        quote = quotes.create(store: "https://s.example", product_id: "1", qty: 1, total: 1999, currency: "USD",
                              title: "Kettle")
        env = { "HOME" => home, "PORTAGE_ENV_FILE" => File.join(home, ".env"), "LANG" => "en_US.UTF-8",
                "LC_ALL" => "en_US.UTF-8" }
        with_env(env) { yield quote["quote_id"], quotes }
      end
    end

    def approve(quote_id, **params)
      tool = Portage::Cli::Mcp::Server.build_tool("approve_quote", tools.fetch("approve_quote"),
                                                  Portage::Cli::Mcp::Runner.new)
      result = tool.call(quote_id: quote_id, **params)
      JSON.parse(result.content.first[:text])
    end

    it "returns needs_approval for a relayed yes and approves nothing" do
      with_home("require_approval" => "person") do |quote_id, quotes|
        report = approve(quote_id, relayed_yes: true)

        expect(report).to include("outcome" => "needs_approval", "quote_id" => quote_id)
        expect(report["message"]).to include("own terminal")
        expect(quotes.find(quote_id)["approved"]).to be(false)
        expect(quotes.find(quote_id)["approved_by"]).to be_nil
      end
    end

    it "does approve a relayed yes under the default policy, so the subprocess wiring is real" do
      with_home("require_approval" => "any") do |quote_id, quotes|
        report = approve(quote_id, relayed_yes: true)

        expect(report).to include("outcome" => "approved", "approved_by" => "agent_relayed")
        expect(quotes.find(quote_id)["approved_by"]).to eq("agent_relayed")
      end
    end

    it "approves nothing without relayed_yes, even under the default policy" do
      with_home("require_approval" => "any") do |quote_id, quotes|
        expect(approve(quote_id)).to include("outcome" => "needs_approval")
        expect(quotes.find(quote_id)["approved_by"]).to be_nil
      end
    end
  end

  describe "metadata" do
    it "has exactly the Phase 4 tools, and never more than 15" do
      expect(tools.keys).to contain_exactly("find_products", "search_catalogue", "compare_prices", "check_store",
                                            "get_status", "list_orders", "quote_purchase", "pick_offer",
                                            "approve_quote", "buy_quote", "hand_off", "reconcile_orders",
                                            "import_browser_history", "add_store")
      expect(tools.size).to be <= 15
    end

    # [read_only, destructive, idempotent, open_world]
    {
      "find_products" => [true, false, true, true], "search_catalogue" => [true, false, true, false],
      "compare_prices" => [true, false, true, true], "check_store" => [true, false, true, true],
      "get_status" => [true, false, true, false], "list_orders" => [true, false, true, false],
      "quote_purchase" => [false, false, false, true], "pick_offer" => [false, false, false, true],
      "approve_quote" => [false, false, true, false], "buy_quote" => [false, true, false, true],
      "hand_off" => [false, false, false, true], "reconcile_orders" => [false, false, true, true],
      "import_browser_history" => [false, false, false, true], "add_store" => [false, false, false, true]
    }.each do |name, (read_only, destructive, idempotent, open_world)|
      it "annotates #{name} read_only=#{read_only} destructive=#{destructive} open_world=#{open_world}" do
        annotations = Portage::Cli::Mcp::Server.build_tool(name, tools.fetch(name), runner).annotations_value.to_h

        expect(annotations).to include(readOnlyHint: read_only, destructiveHint: destructive,
                                       idempotentHint: idempotent, openWorldHint: open_world,
                                       title: tools.fetch(name)[:title])
      end
    end

    it "says in every description that results are untrusted, and describes every param" do
      tools.each do |name, spec|
        expect(spec[:description]).to include(described_class::UNTRUSTED), name
        spec[:properties].each { |param, schema| expect(schema[:description]).not_to be_nil, "#{name}.#{param}" }
      end
    end

    it "says quote_purchase never charges, and buy_quote is the only spender" do
      expect(tools.fetch("quote_purchase")[:description]).to include("never a charge")
      expect(tools.fetch("buy_quote")[:description]).to include("only tool that can spend")
      expect(tools.fetch("hand_off")[:description]).to include("never charges")
      expect(tools.fetch("quote_purchase")[:description]).to include("approve_quote").and include("buy_quote")
        .and include("hand_off")
    end
  end
end

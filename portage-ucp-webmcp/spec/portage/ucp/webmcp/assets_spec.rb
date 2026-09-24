require "spec_helper"

# The browser-side scripts against pages that aren't Portage-powered: the
# point of the outbound transport is that any store's WebMCP tools work, on
# whichever WebMCP surface the browser actually offers.
RSpec.describe "WebMCP page scripts", :node do
  let(:browser) { NodeBrowser.new }
  let(:session) { Portage::Ucp::WebMcp.connect(evaluate: ->(expression) { browser.evaluate(expression) }) }

  after { browser.close }

  def page_json(expression)
    JSON.parse(browser.evaluate("Promise.resolve(#{expression}).then((value) => JSON.stringify(value))"))
  end

  describe "polyfill.js" do
    before { browser.evaluate(Portage::Ucp::WebMcp.polyfill_js) }

    it "installs one spec-shaped ModelContext on document and navigator" do
      expect(page_json("document.modelContext === navigator.modelContext")).to be(true)
      expect(page_json("['registerTool', 'getTools', 'executeTool', 'unregisterTool']" \
                       ".every((m) => typeof document.modelContext[m] === 'function')")).to be(true)
    end

    it "validates registrations the way the spec does" do
      results = page_json(<<~JS)
        Promise.all([
          document.modelContext.registerTool({ name: "bad name!", description: "x", execute() {} }),
          document.modelContext.registerTool({ name: "ok", execute() {} }),
          document.modelContext.registerTool({ name: "ok", description: "x" }),
          document.modelContext.registerTool({ name: "dup", description: "x", execute() {} })
            .then(() => document.modelContext.registerTool({ name: "dup", description: "x", execute() {} }))
        ].map((p) => p.then(() => "resolved", (e) => e.message)))
      JS

      expect(results).to eq(["invalid tool name", "tool description is required",
                             "tool execute must be a function", "tool already registered: dup"])
    end

    it "unregisters on the registration's AbortSignal and stringifies executeTool results" do
      results = page_json(<<~JS)
        (async () => {
          const controller = new AbortController();
          await document.modelContext.registerTool(
            { name: "echo", description: "echo", execute: (input) => ({ echoed: input }) },
            { signal: controller.signal }
          );
          const [tool] = await document.modelContext.getTools();
          const output = await document.modelContext.executeTool(tool, { a: 1 });
          controller.abort();
          return [typeof output, JSON.parse(output), (await document.modelContext.getTools()).length];
        })()
      JS

      expect(results).to eq(["string", { "echoed" => { "a" => 1 } }, 0])
    end

    it "leaves a native implementation alone" do
      fresh = NodeBrowser.new
      fresh.evaluate("document.modelContext = { native: true }")
      fresh.evaluate(Portage::Ucp::WebMcp.polyfill_js)

      expect(fresh.evaluate("JSON.stringify([document.modelContext.native, !!window.__portageWebMcpPolyfill])"))
        .to eq("[true,false]")
    ensure
      fresh&.close
    end
  end

  describe "consumer.js against a third-party store's own tools" do
    before do
      browser.evaluate(Portage::Ucp::WebMcp.polyfill_js)
      browser.evaluate(<<~JS)
        document.modelContext.registerTool({
          name: "findProducts", description: "Search products",
          inputSchema: { type: "object", properties: { query: { type: "string" }, limit: { type: "integer" } } },
          execute: async ({ query }) => ({ products: [{ id: "sku-1", title: query + " mug" }] })
        });
        document.modelContext.registerTool({
          name: "search_catalog", description: "UCP-shaped search",
          inputSchema: { type: "object", properties: { catalog: { type: "object" }, meta: { type: "object" } } },
          execute: async (input) => ({ structuredContent: { received: input }, content: [] })
        });
        document.modelContext.registerTool({
          name: "get_order", description: "Always fails",
          execute: async () => { throw new Error("orders are offline") }
        });
      JS
    end

    it "lists what the page registered" do
      expect(session.instance_variable_get(:@transport).tools.map { |t| t["name"] })
        .to eq(%w[findProducts search_catalog get_order])
    end

    it "calls a differently-named tool through tool_names:, returning its plain result" do
      mapped = Portage::Ucp::WebMcp.connect(evaluate: ->(e) { browser.evaluate(e) },
                                            tool_names: { search_catalog: "findProducts" })

      expect(mapped.search_catalog(query: "blue")).to eq("products" => [{ "id" => "sku-1", "title" => "blue mug" }])
    end

    it "sends a UCP-shaped tool the nested UCP body" do
      received = session.search_catalog(query: "mug", limit: 2, context: { address_country: "US" })["received"]

      expect(received).to eq("catalog" => { "query" => "mug", "pagination" => { "limit" => 2 },
                                            "context" => { "address_country" => "US" } })
    end

    it "raises ServerError when the page's tool throws" do
      expect { session.get_order(order_id: "o1") }
        .to raise_error(Portage::Ucp::Client::ServerError, /orders are offline/)
    end

    it "raises ToolNotFoundError listing the page's tools for an action nothing answers" do
      expect { session.get_cart(cart_id: "c1") }
        .to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError, /findProducts, search_catalog, get_order/)
    end
  end

  describe "registrar.js re-registering against a slow, spec-shaped modelContext" do
    # A fake modelContext whose registerTool takes __DELAY_MS__ to settle and
    # rejects a name still held by an earlier registration — the two things
    # a real spec-compliant browser does that a synchronous test double
    # wouldn't: enough to actually race two script generations against each
    # other instead of asserting on the happy path.
    let(:slow_model_context_js) do
      <<~JS
        (function () {
          var tools = new Map();
          document.modelContext = {
            registerTool: function (tool, options) {
              return new Promise(function (resolve, reject) {
                setTimeout(function () {
                  if (tools.has(tool.name)) { reject(new Error("tool already registered: " + tool.name)); return; }
                  tools.set(tool.name, tool);
                  var signal = options && options.signal;
                  if (signal) signal.addEventListener("abort", function () { tools.delete(tool.name); });
                  resolve({ unregister: function () { tools.delete(tool.name); } });
                }, __DELAY_MS__);
              });
            },
            unregisterTool: function (name) { tools.delete(name); },
            getTools: function () { return Promise.resolve(Array.from(tools.keys())); }
          };
        })();
      JS
    end

    def install_slow_context(delay_ms:)
      browser.evaluate(slow_model_context_js.sub("__DELAY_MS__", delay_ms.to_s))
    end

    let(:registrar) do
      Portage::Ucp::WebMcp::Registrar.new(catalog: Store.catalog(only: %w[search_catalog create_cart]),
                                          endpoint: "/ucp/webmcp")
    end

    it "awaits the previous generation's in-flight registerTool calls before the next one registers, " \
       "so a fast reload never collides on a name" do
      install_slow_context(delay_ms: 30)
      script = registrar.to_js

      browser.evaluate(script)
      browser.evaluate(script) # re-run before the first generation's registerTool has resolved

      sleep 0.3 # real wall-clock time for the fake browser's setTimeouts to fire
      browser.evaluate("Promise.resolve().then(() => null)")

      names = page_json("document.modelContext.getTools()")
      expect(names).to match_array(%w[search_catalog create_cart])
      expect(page_json("window.portageWebMcp.errors")).to eq([])
    end

    it "bounds the wait with reregisterWaitMs instead of blocking on a previous generation that never settles" do
      install_slow_context(delay_ms: 10)
      # A registerTool that never resolves: the previous generation's own
      # `unregister()` would otherwise wait on it forever.
      browser.evaluate(<<~JS)
        document.modelContext.registerTool = function () { return new Promise(function () {}); };
      JS
      stuck = Portage::Ucp::WebMcp::Registrar.new(catalog: Store.catalog(only: %w[search_catalog]),
                                                  endpoint: "/ucp/webmcp", reregister_wait_ms: 50).to_js
      browser.evaluate(stuck)

      install_slow_context(delay_ms: 10) # a fresh, responsive modelContext for the next generation
      browser.evaluate(stuck)

      sleep 0.3
      browser.evaluate("Promise.resolve().then(() => null)")

      expect(page_json("document.modelContext.getTools()")).to eq(["search_catalog"])
    end

    it "still registers normally against a slow modelContext when there is no previous generation to await" do
      install_slow_context(delay_ms: 30)
      browser.evaluate(registrar.to_js)

      sleep 0.1
      browser.evaluate("Promise.resolve().then(() => null)")

      expect(page_json("document.modelContext.getTools()")).to match_array(%w[search_catalog create_cart])
    end

    it "survives a previous generation whose own registerTool settles after reregister_wait_ms, " \
       "against the same persistent modelContext" do
      # A registerTool whose delay can be changed mid-test, so the previous
      # generation's calls are the slow ones (slower than reregister_wait_ms)
      # while the next generation's calls, against that very same
      # modelContext (never reinstalled), are fast — the one case
      # REREGISTER_WAIT_MS's bound is meant to make safe: a previous
      # generation that's still in flight when the bound is exceeded, not
      # one that was isolated onto a fresh modelContext.
      browser.evaluate(<<~JS)
        (function () {
          var tools = new Map();
          window.__regDelayMs = 300;
          document.modelContext = {
            registerTool: function (tool, options) {
              var delay = window.__regDelayMs;
              return new Promise(function (resolve, reject) {
                setTimeout(function () {
                  if (tools.has(tool.name)) { reject(new Error("tool already registered: " + tool.name)); return; }
                  tools.set(tool.name, tool);
                  var signal = options && options.signal;
                  if (signal) signal.addEventListener("abort", function () { tools.delete(tool.name); });
                  resolve({ unregister: function () { tools.delete(tool.name); } });
                }, delay);
              });
            },
            unregisterTool: function (name) { tools.delete(name); },
            getTools: function () { return Promise.resolve(Array.from(tools.keys())); }
          };
        })();
      JS

      slow = Portage::Ucp::WebMcp::Registrar.new(catalog: Store.catalog(only: %w[search_catalog create_cart]),
                                                 endpoint: "/ucp/webmcp", reregister_wait_ms: 50).to_js
      browser.evaluate(slow) # generation 1: its registerTool calls are in flight for the next 300ms

      browser.evaluate("window.__regDelayMs = 5;")
      browser.evaluate(slow) # generation 2: bounded wait expires at 50ms, then registers fast

      sleep 0.4 # long enough for generation 1's 300ms registerTool calls to finally settle
      browser.evaluate("Promise.resolve().then(() => null)")

      names = page_json("document.modelContext.getTools()")
      expect(names).to match_array(%w[search_catalog create_cart])
      expect(page_json("window.portageWebMcp.registered")).to match_array(%w[search_catalog create_cart])
    end
  end

  describe "registrar.js against a page with no modelContext at all" do
    it "records the reason instead of raising, even on a second load" do
      script = Portage::Ucp::WebMcp::Registrar.new(
        catalog: Store.catalog(only: %w[search_catalog]), endpoint: "/ucp/webmcp"
      ).to_js

      browser.evaluate(script)
      browser.evaluate(script)

      expect(page_json("window.portageWebMcp.reason")).to eq("no_model_context")
    end
  end

  describe "consumer.js against other WebMCP surfaces" do
    it "uses navigator.modelContextTesting (listTools + executeTool with a JSON string)" do
      browser.evaluate(<<~JS)
        navigator.modelContextTesting = {
          listTools: () => [{ name: "get_cart", description: "cart",
                              inputSchema: JSON.stringify({ type: "object", properties: { cart_id: {} } }) }],
          executeTool: async (name, json) => JSON.stringify({ structuredContent: { name, args: JSON.parse(json) } })
        };
      JS

      expect(session.get_cart(cart_id: "c1")).to eq("name" => "get_cart", "args" => { "cart_id" => "c1" })
    end

    it "uses a userland listTools + callTool polyfill" do
      browser.evaluate(<<~JS)
        navigator.modelContext = {
          listTools: async () => ({ tools: [{ name: "get_order", description: "order", inputSchema: {} }] }),
          callTool: async ({ name, arguments: args }) => ({ content: [{ type: "text", text: JSON.stringify({ name, args }) }] })
        };
      JS

      expect(session.get_order(order_id: "o9")).to eq("name" => "get_order", "args" => { "order_id" => "o9" })
    end
  end
end

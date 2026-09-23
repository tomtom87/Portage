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

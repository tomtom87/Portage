require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Transport do
  let(:bridge) { FakeBridge.new }
  let(:transport) { described_class.new(bridge: bridge) }
  let(:session) { Portage::Ucp::Client::Session.new(transport: transport) }

  def mcp_result(structured)
    { "content" => [{ "type" => "text", "text" => JSON.generate(structured) }], "structuredContent" => structured }
  end

  describe "flat-shaped tools (this gem's own registrar, or any page taking Session's arguments as-is)" do
    it "sends Session's arguments flat and unwraps an MCP CallToolResult" do
      bridge.register("search_catalog", properties: { "query" => {}, "limit" => {} }) do |_input|
        mcp_result("products" => [{ "id" => "mug" }])
      end

      expect(session.search_catalog(query: "mug", limit: 3)).to eq("products" => [{ "id" => "mug" }])
      expect(bridge.calls.last).to eq(name: "search_catalog", input: { "query" => "mug", "limit" => 3 })
    end

    it "drops the real-UCP wire arguments Loopback/Stdio drop too" do
      bridge.register("create_checkout", properties: { "line_items" => {}, "idempotency_key" => {} }) { {} }

      session.create_checkout(line_items: [{ product_id: "mug", quantity: 1 }], cart_id: "c1",
                              context: { address_country: "US" }, idempotency_key: "k1")

      expect(bridge.calls.last[:input]).to eq(
        "line_items" => [{ "product_id" => "mug", "quantity" => 1 }], "idempotency_key" => "k1"
      )
    end

    it "carries meta as the registrar's reserved _meta key, with the agent profile under ucp-agent.profile" do
      bridge.register("get_order", properties: { "order_id" => {} }) { {} }

      session.get_order(order_id: "o1", meta: { agent_profile: "https://agent.example/profile" })

      expect(bridge.calls.last[:input]["_meta"]).to eq(
        "agent_profile" => "https://agent.example/profile", "ucp-agent.profile" => "https://agent.example/profile"
      )
    end

    it "converts value objects to plain hashes before they cross into the page" do
      bridge.register("update_checkout", properties: { "checkout_id" => {}, "line_items" => {} }) { {} }
      item = Struct.new(:product_id, :quantity).new("mug", 2)

      session.update_checkout(checkout_id: "chk", line_items: [item], idempotency_key: "k")

      expect(bridge.calls.last[:input]["line_items"]).to eq([{ "product_id" => "mug", "quantity" => 2 }])
    end
  end

  describe "UCP-shaped tools (a third-party store registering native-UCP-style tools)" do
    it "nests arguments exactly as Transports::Http does, from the tool's own schema" do
      bridge.register("search_catalog", properties: { "catalog" => {}, "meta" => {} }) { |_| "{}" }

      session.search_catalog(query: "mug", limit: 5, context: { currency: "USD" },
                             meta: { agent_profile: "https://agent.example/p" })

      expect(bridge.calls.last[:input]).to eq(
        "catalog" => { "query" => "mug", "pagination" => { "limit" => 5 }, "context" => { "currency" => "USD" } },
        "meta" => { "ucp-agent" => { "profile" => "https://agent.example/p" } }
      )
    end

    it "treats an id + meta schema as UCP-shaped and folds the idempotency key into meta" do
      bridge.register("cancel_cart", properties: { "id" => {}, "meta" => {} }) { {} }

      session.cancel_cart(cart_id: "cart_1", idempotency_key: "k9")

      expect(bridge.calls.last[:input]).to eq("id" => "cart_1", "meta" => { "idempotency-key" => "k9" })
    end

    it "doesn't demand an agent profile the way Http does — the browser session is the caller" do
      bridge.register("get_product", properties: { "catalog" => {} }) { {} }

      expect { session.get_product(product_id: "p1") }.not_to raise_error
      expect(bridge.calls.last[:input]).to eq("catalog" => { "id" => "p1" })
    end

    it "can be forced with wire: regardless of schema" do
      forced = described_class.new(bridge: bridge.register("get_cart") { {} }, wire: :ucp)

      forced.call_tool(name: "get_cart", arguments: { cart_id: "c1" })

      expect(bridge.calls.last[:input]).to eq("id" => "c1")
    end
  end

  describe "tool name resolution" do
    it "prefers tool_names:, then prefix, then the bare action" do
      bridge.register("shop.find_products") { { "via" => "map" } }
      bridge.register("acme.search_catalog") { { "via" => "prefix" } }
      bridge.register("search_catalog") { { "via" => "bare" } }

      mapped = described_class.new(bridge: bridge, prefix: "acme.",
                                   tool_names: { search_catalog: "shop.find_products" })
      prefixed = described_class.new(bridge: bridge, prefix: "acme.")

      expect(mapped.call_tool(name: "search_catalog", arguments: {})).to eq("via" => "map")
      expect(prefixed.call_tool(name: "search_catalog", arguments: {})).to eq("via" => "prefix")
      expect(transport.call_tool(name: "search_catalog", arguments: {})).to eq("via" => "bare")
    end

    it "re-reads the page once before giving up, for tools registered after load" do
      transport.tools
      bridge.register("get_order") { { "id" => "o1" } }

      expect(transport.call_tool(name: "get_order", arguments: { order_id: "o1" })).to eq("id" => "o1")
      expect(bridge.list_count).to eq(2)
    end

    it "raises ToolNotFoundError naming what the page does register" do
      bridge.register("add_to_bag")

      expect { transport.call_tool(name: "create_cart", arguments: {}) }
        .to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError, /add_to_bag.*tool_names:/) { |e|
          expect(e.available).to eq(["add_to_bag"])
        }
    end

    it "waits out a page dropping and re-registering its tools, then sends the call again" do
      bridge.register("get_cart") { { "id" => "c1" } }.drop_for("get_cart", misses: 2)
      allow(transport).to receive(:sleep)

      expect(transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" })).to eq("id" => "c1")
      expect(bridge.calls.size).to eq(3)
      expect(transport).to have_received(:sleep).with(described_class::REREGISTER_POLL).twice
    end

    context "when the page's tool says the page isn't ready yet" do
      let(:not_ready) do
        "Error: Standard Actions are not available. Ensure Shopify Standard Actions are available before " \
          "calling cart tools.\nRecovery: Try again - this is usually a transient error."
      end

      def answer_not_ready(times, with:)
        misses = times
        bridge.register("get_cart") do
          next { "id" => "c1" } if (misses -= 1).negative?
          raise Portage::Ucp::Client::ServerError.new(not_ready, payload: nil) if with == :throw

          result = { "content" => [{ "type" => "text", "text" => not_ready }], "isError" => true }
          with == :json ? JSON.generate(result) : result
        end
      end

      it "waits and sends the call again when the tool throws it" do
        answer_not_ready(2, with: :throw)
        allow(transport).to receive(:sleep)

        expect(transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" })).to eq("id" => "c1")
        expect(bridge.calls.size).to eq(3)
      end

      it "waits and sends the call again when the tool returns it as isError" do
        answer_not_ready(1, with: :result)
        allow(transport).to receive(:sleep)

        expect(transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" })).to eq("id" => "c1")
        expect(bridge.calls.size).to eq(2)
      end

      # How Shopify storefronts' tools answer through the page (live, 2026-09-24).
      it "waits and sends the call again when the tool returns it as a JSON string" do
        answer_not_ready(1, with: :json)
        allow(transport).to receive(:sleep)

        expect(transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" })).to eq("id" => "c1")
        expect(bridge.calls.size).to eq(2)
      end

      it "reports the page's own error once reregister_wait: runs out" do
        answer_not_ready(99, with: :throw)
        impatient = described_class.new(bridge: bridge, reregister_wait: 0)

        expect { impatient.call_tool(name: "get_cart", arguments: { cart_id: "c1" }) }
          .to raise_error(Portage::Ucp::Client::ServerError, /Standard Actions are not available/)
        expect(bridge.calls.size).to eq(1)
      end

      it "never retries any other tool error" do
        bridge.register("get_cart") { raise Portage::Ucp::Client::ServerError.new("Sold out", payload: nil) }

        expect { transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" }) }
          .to raise_error(Portage::Ucp::Client::ServerError, /Sold out/)
        expect(bridge.calls.size).to eq(1)
      end
    end

    it "gives up with ToolNotFoundError once reregister_wait: runs out" do
      bridge.register("get_cart").drop_for("get_cart", misses: 99)
      impatient = described_class.new(bridge: bridge, reregister_wait: 0)

      expect { impatient.call_tool(name: "get_cart", arguments: { cart_id: "c1" }) }
        .to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError, /get_cart/)
      expect(bridge.calls.size).to eq(1)
    end

    # A fake clock: each bridge call takes 0.3s, each sleep takes what it
    # asks for, and nothing else moves time.
    it "keeps every retry and sleep inside the one reregister_wait: deadline" do
      bridge.register("get_cart").drop_for("get_cart", misses: 99)
      patient = described_class.new(bridge: bridge, reregister_wait: 1.0)
      now = 0.0
      sleep_ends = []
      allow(patient).to receive(:monotonic_now) { now }
      allow(patient).to receive(:sleep) { |seconds| sleep_ends << (now += seconds) }
      allow(bridge).to receive(:execute_tool).and_wrap_original do |original, *args|
        now += 0.3
        original.call(*args)
      end

      expect { patient.call_tool(name: "get_cart", arguments: { cart_id: "c1" }) }
        .to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError)
      expect(sleep_ends.max).to be <= 1.0
      expect(now).to be <= 1.0 + 0.3
      expect(bridge.calls.size).to eq(3)
    end

    it "caches the tool list until refresh!" do
      bridge.register("get_cart") { {} }
      2.times { transport.call_tool(name: "get_cart", arguments: { cart_id: "c" }) }
      transport.refresh!.tools

      expect(bridge.list_count).to eq(2)
    end
  end

  describe "results" do
    before { bridge.register("get_order", properties: { "order_id" => {} }) { |_| result } }

    let(:call) { transport.call_tool(name: "get_order", arguments: { order_id: "o1" }) }

    context "when the spec's executeTool hands back a JSON string" do
      let(:result) { JSON.generate(mcp_result("id" => "o1")) }

      it("parses and unwraps it") { expect(call).to eq("id" => "o1") }
    end

    context "when a CallToolResult carries only text content" do
      let(:result) { { "content" => [{ "type" => "text", "text" => '{"id":"o1"}' }] } }

      it("parses the text as JSON") { expect(call).to eq("id" => "o1") }
    end

    context "when the tool returns a plain object" do
      let(:result) { { "id" => "o1", "status" => "open" } }

      it("returns it as-is") { expect(call).to eq("id" => "o1", "status" => "open") }
    end

    context "when the tool returns non-JSON text" do
      let(:result) { "Order o1 is on its way" }

      it("returns the text") { expect(call).to eq("Order o1 is on its way") }
    end

    context "when the tool reports isError" do
      let(:result) do
        { "isError" => true,
          "content" => [{ "type" => "text", "text" => '{"messages":[{"content":"Sold out","code":"oos"}]}' }] }
      end

      it "raises ServerError with the parsed payload, same as stdio/HTTP" do
        expect { call }.to raise_error(Portage::Ucp::Client::ServerError) { |e| expect(e.summary).to eq("Sold out") }
      end
    end
  end

  it "rejects an unknown wire:" do
    expect { described_class.new(bridge: bridge, wire: :xml) }.to raise_error(ArgumentError, /wire/)
  end

  it "keeps Session's client-side guards in front of it" do
    bridge.register("complete_checkout") { {} }

    expect { session.complete_checkout(checkout_id: "c", payment_token: "4111111111111111") }
      .to raise_error(Portage::Ucp::RawPanRejectedError)
    expect(bridge.calls).to be_empty
  end
end

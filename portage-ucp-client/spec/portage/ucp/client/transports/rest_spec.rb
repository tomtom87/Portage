require "spec_helper"

RSpec.describe Portage::Ucp::Client::Transports::Rest do
  let(:base) { "https://shop.example/ucp/2026-08-25" }
  let(:profile) { "https://agent.example/profile" }
  let(:meta) { { agent_profile: profile } }
  let(:ok) { { status: 200, body: '{"id":"x"}', headers: { "Content-Type" => "application/json" } } }
  let(:errors) { Portage::Ucp::Client }

  subject(:transport) { described_class.new(url: base) }

  def call(name, arguments = {}, meta: self.meta)
    transport.call_tool(name: name, arguments: arguments, meta: meta)
  end

  # action, arguments, verb, path, expected JSON body (nil = no body)
  [
    ["search_catalog", { query: "shoes", limit: 2 }, :post, "/catalog/search",
     { "query" => "shoes", "pagination" => { "limit" => 2 } }],
    ["lookup_catalog", { product_ids: %w[a b] }, :post, "/catalog/lookup", { "ids" => %w[a b] }],
    ["get_product", { product_id: "p1" }, :post, "/catalog/product", { "id" => "p1" }],
    ["create_cart", { line_items: [{ product_id: "p1", quantity: 2 }] }, :post, "/carts",
     { "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 2 }] }],
    ["get_cart", { cart_id: "c 1" }, :get, "/carts/c+1", nil],
    ["update_cart", { cart_id: "c1", line_items: [{ product_id: "p1", quantity: 1 }] }, :put, "/carts/c1",
     { "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }] }],
    ["cancel_cart", { cart_id: "c1" }, :post, "/carts/c1/cancel", nil],
    ["create_checkout", { line_items: [{ product_id: "p1", quantity: 1 }], cart_id: "c1" }, :post,
     "/checkout-sessions",
     { "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }], "cart_id" => "c1" }],
    ["get_checkout", { checkout_id: "k1" }, :get, "/checkout-sessions/k1", nil],
    ["update_checkout", { checkout_id: "k1", line_items: [{ product_id: "p1", quantity: 3 }] }, :put,
     "/checkout-sessions/k1", { "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 3 }] }],
    ["cancel_checkout", { checkout_id: "k1" }, :post, "/checkout-sessions/k1/cancel", nil],
    ["get_order", { order_id: "o1" }, :get, "/orders/o1", nil]
  ].each do |action, arguments, verb, path, body|
    it "maps #{action} to #{verb.upcase} #{path}" do
      stub = stub_request(verb, base + path).to_return(ok)
      stub.with(body: body.to_json) if body

      expect(call(action, arguments)).to eq("id" => "x")
      expect(stub).to have_been_requested
      expect(a_request(verb, base + path).with { |r| r.body.nil? || r.body.empty? }).to have_been_made unless body
    end
  end

  it "sends the payment instrument as the bare checkout body, id in the path" do
    instrument = { "id" => "instrument-key-1", "handler_id" => "dev.shopify.card", "type" => "card",
                   "credential" => { "token" => "tok", "type" => "dev.shopify.card_token" } }
    stub = stub_request(:post, "#{base}/checkout-sessions/k1/complete")
           .with(body: { "payment" => { "instruments" => [instrument] } }.to_json).to_return(ok)

    call("complete_checkout", { checkout_id: "k1", payment_token: "tok", idempotency_key: "key-1" })

    expect(stub).to have_been_requested
  end

  it "sends the UCP-Agent, Idempotency-Key, JSON and caller headers" do
    stub = stub_request(:post, "#{base}/carts").with(headers: {
                                                       "UCP-Agent" => %(profile="#{profile}"),
                                                       "Idempotency-Key" => "key-1",
                                                       "Content-Type" => "application/json",
                                                       "Accept" => "application/json",
                                                       "Authorization" => "Bearer t",
                                                       "User-Agent" => errors::USER_AGENT
                                                     }).to_return(ok)

    described_class.new(url: "#{base}/", headers: { "Authorization" => "Bearer t" })
                   .call_tool(name: "create_cart", arguments: { line_items: [], idempotency_key: "key-1" },
                              meta: meta)

    expect(stub).to have_been_requested
  end

  it "keeps a caller's own User-Agent" do
    stub = stub_request(:get, "#{base}/orders/o1").with(headers: { "User-Agent" => "mine/1" }).to_return(ok)

    described_class.new(url: base, headers: { "user-agent" => "mine/1" })
                   .call_tool(name: "get_order", arguments: { order_id: "o1" }, meta: meta)

    expect(stub).to have_been_requested
  end

  it "omits Idempotency-Key when there is none" do
    stub_request(:get, "#{base}/orders/o1").to_return(ok)
    call("get_order", { order_id: "o1" })

    expect(a_request(:get, "#{base}/orders/o1").with { |r| !r.headers.key?("Idempotency-Key") }).to have_been_made
  end

  it "passes the proxy to Faraday" do
    expect(Faraday).to receive(:new).with(hash_including(proxy: "http://proxy:8080")).and_call_original

    described_class.new(url: base, proxy: "http://proxy:8080")
  end

  it "raises MissingAgentProfileError without an agent profile" do
    expect { call("get_order", { order_id: "o1" }, meta: nil) }.to raise_error(errors::MissingAgentProfileError)
    expect { call("get_order", { order_id: "o1" }, meta: {}) }.to raise_error(errors::MissingAgentProfileError)
  end

  describe "errors" do
    it "maps a non-2xx to ServerError carrying the UCP message and payload" do
      body = { "messages" => [{ "type" => "error", "code" => "out_of_stock", "content" => "Sold out",
                                "severity" => "unrecoverable" }] }
      stub_request(:post, "#{base}/carts").to_return(status: 422, body: body.to_json)

      expect { call("create_cart", { line_items: [] }) }.to raise_error(errors::ServerError) { |e|
        expect(e.message).to eq("HTTP 422: Sold out")
        expect(e.payload).to eq(body)
        expect(e.summary).to eq("Sold out")
      }
    end

    it "falls back to the raw body when it isn't a UCP error document" do
      stub_request(:get, "#{base}/orders/o1").to_return(status: 502, body: "bad gateway")

      expect { call("get_order", { order_id: "o1" }) }
        .to raise_error(errors::ServerError, "HTTP 502: bad gateway")
    end

    it "raises ServerError for a 2xx that isn't a JSON object" do
      stub_request(:get, "#{base}/orders/o1").to_return(status: 200, body: "<html>")

      expect { call("get_order", { order_id: "o1" }) }.to raise_error(errors::ServerError)
    end

    it "maps a complete_checkout permission refusal to PaymentPermissionError" do
      stub_request(:post, "#{base}/checkout-sessions/k1/complete")
        .to_return(status: 403, body: { "messages" => [{ "content" => "Forbidden" }] }.to_json)

      expect { call("complete_checkout", { checkout_id: "k1", payment_token: "t" }) }
        .to raise_error(errors::PaymentPermissionError)
    end

    it "matches the shared refusal pattern on other statuses for complete_checkout" do
      stub_request(:post, "#{base}/checkout-sessions/k1/complete")
        .to_return(status: 400, body: { "messages" => [{ "content" => "channel not enabled" }] }.to_json)

      expect { call("complete_checkout", { checkout_id: "k1", payment_token: "t" }) }
        .to raise_error(errors::PaymentPermissionError)
    end

    it "leaves a 403 on any other action a ServerError" do
      stub_request(:get, "#{base}/orders/o1").to_return(status: 403, body: "{}")

      expect { call("get_order", { order_id: "o1" }) }.to raise_error(errors::ServerError)
    end
  end

  %w[link_identity create_payment_enrollment get_payment_enrollment bogus_action].each do |action|
    it "raises UnsupportedWireShapeError naming #{action}" do
      expect { call(action, {}) }.to raise_error(errors::UnsupportedWireShapeError, /#{action}/)
    end
  end
end

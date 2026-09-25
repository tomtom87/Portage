require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Rack::CallEndpoint do
  include Rack::Test::Methods

  let(:catalog) { Store.catalog }
  let(:endpoint_options) { {} }
  let(:app) { described_class.new(catalog: catalog, **endpoint_options) }
  let(:origin) { "http://example.org" } # Rack::Test's default host

  def rpc(method, params = {}, headers = {})
    header "Origin", headers.fetch(:origin, origin) unless headers[:origin] == :none
    header "X-Csrf-Token", headers[:csrf] if headers[:csrf]
    post "/", JSON.generate(jsonrpc: "2.0", id: 7, method: method, params: params),
         "CONTENT_TYPE" => headers.fetch(:content_type, "application/json")
  end

  def body = JSON.parse(last_response.body)

  def raw_rpc(raw_body, headers = {})
    header "Origin", headers.fetch(:origin, origin) unless headers[:origin] == :none
    post "/", raw_body, "CONTENT_TYPE" => headers.fetch(:content_type, "application/json")
  end

  it "runs tools/call through the catalog's Mcp::Server and returns its result" do
    rpc("tools/call", name: "search_catalog", arguments: { query: "mug", limit: 5 })

    expect(last_response.status).to eq(200)
    expect(body["id"]).to eq(7)
    products = body.dig("result", "structuredContent", "products")
    expect(products.map { |p| p["id"] }).to eq(["mug"])
  end

  it "hands the Authenticator the Rack request, so host-app session/CSRF checks work" do
    rpc("tools/call", { name: "create_cart", arguments: { line_items: [{ product_id: "mug", quantity: 1 }],
                                                          idempotency_key: "k1" } },
        { csrf: Store::CSRF_TOKEN })

    expect(body.dig("result", "isError")).to be_falsy
    expect(body.dig("result", "structuredContent", "id")).to be_a(String)
  end

  it "surfaces an Authenticator refusal as a tool error, like every other transport" do
    rpc("tools/call", name: "create_cart", arguments: { line_items: [{ product_id: "mug", quantity: 1 }],
                                                        idempotency_key: "k2" })

    expect(body.dig("result", "isError")).to be(true)
    expect(body.dig("result", "content", 0, "text")).to include("CSRF")
  end

  it "refuses actions the catalog doesn't expose, even though the server has them" do
    rpc("tools/call", name: "link_identity", arguments: { oauth_token: "t" })

    expect(body.dig("error", "code")).to eq(-32_602)
    expect(body.dig("error", "message")).to include("link_identity")
  end

  it "lists only the catalog's tools" do
    rpc("tools/list")

    names = body.dig("result", "tools").map { |t| t["name"] }
    expect(names).to match_array(catalog.actions)
    expect(names).not_to include("link_identity")
  end

  it "allows no JSON-RPC method beyond tools/call and tools/list" do
    rpc("initialize")

    expect(body.dig("error", "code")).to eq(-32_601)
  end

  it "answers a parse error for a body that isn't a JSON object" do
    header "Origin", origin
    post "/", "not json", "CONTENT_TYPE" => "application/json"

    expect(body.dig("error", "code")).to eq(-32_700)
  end

  describe "malformed JSON-RPC that used to crash the dispatcher" do
    it "answers Invalid params instead of raising when params is a string, not an object" do
      raw_rpc(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: "oops"))

      expect(last_response.status).to eq(200)
      expect(body.dig("error", "code")).to eq(-32_602)
    end

    it "answers Invalid params when params is a number" do
      raw_rpc(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: 5))

      expect(body.dig("error", "code")).to eq(-32_602)
    end

    it "answers Invalid params when params is a boolean" do
      raw_rpc(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: true))

      expect(body.dig("error", "code")).to eq(-32_602)
    end

    it "answers Method not found rather than raising for a non-string method" do
      raw_rpc(JSON.generate(jsonrpc: "2.0", id: 1, method: 5, params: {}))

      expect(body.dig("error", "code")).to eq(-32_601)
    end

    it "answers a parse error for a top-level JSON array (a JSON-RPC batch), not a crash" do
      raw_rpc(JSON.generate([{ jsonrpc: "2.0", id: 1, method: "tools/list" }]))

      expect(body.dig("error", "code")).to eq(-32_700)
    end
  end

  describe "max_body_bytes" do
    let(:endpoint_options) { { max_body_bytes: 64 } }
    let(:oversized) do
      JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call",
                    params: { name: "search_catalog", arguments: { query: "x" * 200 } })
    end

    it "rejects a request whose Content-Length exceeds the cap with 413, before reading the body" do
      raw_rpc(oversized)

      expect(last_response.status).to eq(413)
      expect(body.dig("error", "code")).to eq(-32_000)
    end

    it "rejects a body that streams past the cap even when Content-Length under-reports it" do
      env = Rack::MockRequest.env_for("/", method: "POST", input: oversized,
                                           "CONTENT_TYPE" => "application/json", "CONTENT_LENGTH" => "5")
      env["HTTP_ORIGIN"] = origin

      status, _headers, resp_body = app.call(env)

      expect(status).to eq(413)
      expect(JSON.parse(resp_body.first).dig("error", "code")).to eq(-32_000)
    end

    it "accepts a body at or under the cap" do
      small = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
      raw_rpc(small)

      expect(last_response.status).to eq(200)
    end
  end

  describe "call_timeout" do
    context "when the server hangs past it" do
      let(:endpoint_options) { { call_timeout: 0.05 } }

      before do
        server = catalog.server
        def server.dup = self

        def server.handle(payload)
          sleep(0.3)
          super
        end
      end

      it "answers a JSON-RPC error instead of blocking the request indefinitely" do
        rpc("tools/call", name: "search_catalog", arguments: { query: "mug" })

        expect(last_response.status).to eq(200)
        expect(body.dig("error", "code")).to eq(-32_000)
        expect(body.dig("error", "message")).to include("timed out")
      end
    end

    context "with call_timeout: nil" do
      let(:endpoint_options) { { call_timeout: nil } }

      it "does not bound the call" do
        rpc("tools/call", name: "search_catalog", arguments: { query: "mug", limit: 5 })

        expect(last_response.status).to eq(200)
        expect(body.dig("result", "structuredContent", "products")).not_to be_nil
      end
    end
  end

  describe "browser-facing guards" do
    it "rejects a cross-site origin" do
      rpc("tools/list", {}, { origin: "https://evil.example" })

      expect(last_response.status).to eq(403)
    end

    it "rejects a request with no Origin by default" do
      rpc("tools/list", {}, { origin: :none })

      expect(last_response.status).to eq(403)
    end

    it "rejects non-JSON bodies, which a cross-site form could send without preflight" do
      rpc("tools/list", {}, { content_type: "text/plain" })

      expect(last_response.status).to eq(415)
    end

    it "rejects methods other than POST/OPTIONS" do
      header "Origin", origin
      get "/"

      expect(last_response.status).to eq(405)
    end

    context "with an allowed cross-origin storefront" do
      let(:endpoint_options) { { allowed_origins: ["https://shop.example/"] } }

      it "accepts it and answers with credentialed CORS headers" do
        rpc("tools/list", {}, { origin: "https://shop.example" })

        expect(last_response.status).to eq(200)
        expect(last_response.headers["access-control-allow-origin"]).to eq("https://shop.example")
        expect(last_response.headers["access-control-allow-credentials"]).to eq("true")
      end

      it "answers its preflight" do
        header "Origin", "https://shop.example"
        header "Access-Control-Request-Headers", "content-type, x-csrf-token"
        options "/"

        expect(last_response.status).to eq(204)
        expect(last_response.headers["access-control-allow-methods"]).to include("POST")
        expect(last_response.headers["access-control-allow-headers"]).to eq("content-type, x-csrf-token")
      end

      it "no longer accepts its own origin unless listed" do
        rpc("tools/list")

        expect(last_response.status).to eq(403)
      end
    end

    context "with require_origin: false" do
      let(:endpoint_options) { { require_origin: false } }

      it "accepts a request with no Origin" do
        rpc("tools/list", {}, { origin: :none })

        expect(last_response.status).to eq(200)
      end
    end
  end

  # Phase 3 of docs/plans/proxy-support.md.
  describe "reverse-proxy support" do
    def raw_call(payload, env_overrides = {})
      body = JSON.generate(payload)
      env = Rack::MockRequest.env_for("/", method: "POST", input: body, "CONTENT_TYPE" => "application/json")
      env["HTTP_ORIGIN"] = origin
      env.merge!(env_overrides)
      app.call(env)
    end

    describe "Origin/X-Forwarded-Host" do
      let(:endpoint_options) { { trusted_proxies: ["10.0.0.0/8"], forwarded_host_allowed: ["shop.example"] } }

      it "does not let a spoofed X-Forwarded-Host from an untrusted peer widen what's accepted as same-origin" do
        status, _headers, body = raw_call(
          { jsonrpc: "2.0", id: 1, method: "tools/list" },
          "REMOTE_ADDR" => "203.0.113.9", "HTTP_X_FORWARDED_HOST" => "shop.example",
          "HTTP_ORIGIN" => "http://shop.example"
        )

        expect(status).to eq(403)
        expect(JSON.parse(body.first).dig("error", "code")).to eq(-32_600)
      end

      it "does not accept a forwarded host that isn't on forwarded_host_allowed, even from a trusted peer" do
        status, = raw_call(
          { jsonrpc: "2.0", id: 1, method: "tools/list" },
          "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_HOST" => "evil.example",
          "HTTP_ORIGIN" => "http://evil.example"
        )

        expect(status).to eq(403)
      end

      it "accepts the request as same-origin once the forwarded host is both trusted and allowlisted" do
        status, = raw_call(
          { jsonrpc: "2.0", id: 1, method: "tools/list" },
          "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_HOST" => "shop.example",
          "HTTP_ORIGIN" => "http://shop.example"
        )

        expect(status).to eq(200)
      end

      it "still accepts its own (unforwarded) origin — replacing, not widening, what counts as same-origin" do
        status, = raw_call({ jsonrpc: "2.0", id: 1, method: "tools/list" }, "REMOTE_ADDR" => "10.0.0.5")

        expect(status).to eq(200)
      end
    end

    describe "client_ip reaching the RateLimiter" do
      let(:seen_keys) { [] }
      let(:rate_limiter) do
        seen = seen_keys
        Class.new(Portage::Ucp::RateLimiter) do
          define_method(:check!) { |key, _capability| seen << key[:client_ip] }
        end.new
      end
      let(:catalog) { Store.catalog(rate_limiter: rate_limiter) }
      let(:endpoint_options) { { trusted_proxies: ["10.0.0.0/8"] } }
      let(:mutating_params) do
        { name: "create_cart",
          arguments: { line_items: [{ product_id: "mug", quantity: 1 }], idempotency_key: "k-#{SecureRandom.hex(4)}" } }
      end

      it "keys on the resolved right-most-untrusted client, not the trusted proxy's own address" do
        raw_call(
          { jsonrpc: "2.0", id: 1, method: "tools/call", params: mutating_params },
          "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "198.51.100.7",
          "HTTP_X_CSRF_TOKEN" => Store::CSRF_TOKEN
        )

        expect(seen_keys).to eq(["198.51.100.7"])
      end

      it "keys on the plain socket peer when it isn't a trusted proxy, ignoring any X-Forwarded-For it sends" do
        raw_call(
          { jsonrpc: "2.0", id: 1, method: "tools/call", params: mutating_params },
          "REMOTE_ADDR" => "203.0.113.9", "HTTP_X_FORWARDED_FOR" => "198.51.100.7",
          "HTTP_X_CSRF_TOKEN" => Store::CSRF_TOKEN
        )

        expect(seen_keys).to eq(["203.0.113.9"])
      end
    end

    describe "passthrough headers" do
      let(:endpoint_options) do
        { trusted_proxies: ["10.0.0.0/8"], passthrough_headers: ["X-Shop-Locale"], passthrough_forwarded: "replace" }
      end
      let(:captured) { [] }
      let(:search_params) { { name: "search_catalog", arguments: { query: "mug" } } }

      # Same "override .dup/#handle on the catalog's own server" shape the
      # existing call_timeout specs above already use — captures whatever
      # Support::PassthroughContext looks like *during* the dispatched call,
      # which is exactly what Support::Connection would see if the tool
      # made an outbound call right then.
      before do
        server = catalog.server
        def server.dup = self

        captures = captured
        server.define_singleton_method(:handle) do |payload|
          captures << Portage::Ucp::Support::PassthroughContext.current
          super(payload)
        end
      end

      it "raises at construction time if a passthrough header is protected" do
        expect do
          described_class.new(catalog: catalog, passthrough_headers: ["Authorization"])
        end.to raise_error(Portage::Ucp::Support::ProxyConfig::ConfigError, /Authorization/)
      end

      it "is active, with the allowlisted header, for a trusted peer's call" do
        raw_call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: search_params },
                 "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_SHOP_LOCALE" => "en-GB")

        expect(captured.first).to include(headers: { "X-Shop-Locale" => "en-GB" }, forwarded: "replace")
      end

      it "is not active for the same request from an untrusted peer" do
        raw_call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: search_params },
                 "REMOTE_ADDR" => "203.0.113.9", "HTTP_X_SHOP_LOCALE" => "en-GB")

        expect(captured.first).to be_nil
      end

      it "clears once the request finishes, so it never leaks into a later call" do
        raw_call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: search_params },
                 "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_SHOP_LOCALE" => "en-GB")

        expect(Portage::Ucp::Support::PassthroughContext.current).to be_nil
      end

      it "does not leak into a later request from a different (untrusted) peer either" do
        raw_call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: search_params },
                 "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_SHOP_LOCALE" => "en-GB")
        raw_call({ jsonrpc: "2.0", id: 2, method: "tools/call", params: search_params },
                 "REMOTE_ADDR" => "203.0.113.9", "HTTP_X_SHOP_LOCALE" => "en-GB")

        expect(captured.last).to be_nil
      end
    end
  end
end

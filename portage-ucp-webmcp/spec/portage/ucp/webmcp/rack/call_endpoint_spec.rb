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
end

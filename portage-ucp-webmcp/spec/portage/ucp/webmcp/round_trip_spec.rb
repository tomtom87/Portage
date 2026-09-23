require "spec_helper"

# Both halves together, with nothing mocked between them: the merchant's
# Rack::App serves the registrar, the registrar runs in a (node-hosted) page
# and registers on the polyfilled document.modelContext, and the agent's
# Session drives it through the ScriptEvaluator bridge — each call going
# page -> fetch -> CallEndpoint -> Mcp::Server -> ReferenceAdapter.
RSpec.describe "WebMCP round trip", :node do
  let(:catalog_options) { {} }
  let(:registrar_options) { { headers: { "x-csrf-token" => Store::CSRF_TOKEN } } }
  let(:catalog) { Store.catalog(**catalog_options) }
  let(:rack_app) do
    mounted = Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog, registrar_options: registrar_options)
    Rack::Builder.new { map("/ucp") { run mounted } }
  end
  let(:browser) { NodeBrowser.new(rack_app: rack_app) }
  let(:session) { Portage::Ucp::WebMcp.connect(evaluate: ->(expression) { browser.evaluate(expression) }) }

  after { browser.close }

  def load_page(polyfill: true)
    browser.evaluate(Portage::Ucp::WebMcp.polyfill_js) if polyfill
    browser.evaluate(Rack::MockRequest.new(rack_app).get("/ucp/webmcp.js").body)
    browser.evaluate("Promise.resolve().then(() => null)")
  end

  def page_json(expression)
    JSON.parse(browser.evaluate("Promise.resolve(#{expression}).then((value) => JSON.stringify(value))"))
  end

  def last_rpc
    JSON.parse(browser.requests.last["body"])
  end

  it "registers every catalog tool on document.modelContext with its WebMCP annotations" do
    load_page

    registered = page_json("document.modelContext.getTools()")
    expect(registered.map { |t| t["name"] }).to match_array(catalog.tools.map { |t| t["name"] })
    expect(registered.find { |t| t["name"] == "cancel_order" }["annotations"])
      .to eq("readOnlyHint" => false, "consequentialHint" => true)
    expect(registered.find { |t| t["name"] == "search_catalog" }["annotations"])
      .to eq("readOnlyHint" => true, "consequentialHint" => false)
    expect(page_json("window.portageWebMcp.errors")).to eq([])
  end

  it "shops through the page's tools: search, cart, checkout, up to the shopper's own payment step" do
    load_page

    product = session.search_catalog(query: "mug")["products"].first
    cart = session.create_cart(line_items: [{ product_id: product["id"], quantity: 2 }])
    cart = session.update_cart(cart_id: cart["id"], line_items: [{ product_id: product["id"], quantity: 3 }])
    checkout = session.create_checkout(line_items: [{ product_id: product["id"], quantity: 3 }])
    fetched = session.get_checkout(checkout_id: checkout["id"])
    canceled = session.cancel_checkout(checkout_id: checkout["id"])

    expect(product["title"]).to eq("Enamel Mug")
    expect(session.get_cart(cart_id: cart["id"])["line_items"].first["quantity"]).to eq(3)
    expect(fetched).to include("id" => checkout["id"], "status" => checkout["status"])
    expect(canceled["status"]).to eq("canceled")
  end

  it "doesn't expose complete_checkout by default" do
    load_page

    expect { session.complete_checkout(checkout_id: "chk", payment_token: "tok_visa_4242") }
      .to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError)
  end

  it "posts JSON-RPC tools/call to the mounted endpoint with the page's credentials and headers" do
    load_page
    session.get_product(product_id: "tee")

    request = browser.requests.last
    expect(request).to include("url" => "/ucp/webmcp", "method" => "POST", "credentials" => "same-origin")
    expect(request["headers"]).to include("content-type" => "application/json", "x-csrf-token" => Store::CSRF_TOKEN)
    expect(last_rpc).to include("method" => "tools/call",
                                "params" => { "name" => "get_product", "arguments" => { "product_id" => "tee" } })
  end

  it "forwards Session meta as the request's _meta, where Mcp::Server reads the agent profile" do
    load_page
    session.search_catalog(query: "tee", meta: { agent_profile: "https://agent.example/profile.json" })

    expect(last_rpc.dig("params", "_meta", "ucp-agent.profile")).to eq("https://agent.example/profile.json")
    expect(last_rpc.dig("params", "arguments")).not_to have_key("_meta")
  end

  it "has the page fill idempotency_key for a mutating tool an agent calls without one" do
    load_page
    expression = Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.expression(
      "execute", "create_cart", { line_items: [{ product_id: "mug", quantity: 1 }] }
    )
    browser.evaluate(expression)

    expect(last_rpc.dig("params", "arguments", "idempotency_key")).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "surfaces the store's Authenticator refusal as a ServerError" do
    registrar_options.delete(:headers)
    load_page

    expect { session.create_cart(line_items: [{ product_id: "mug", quantity: 1 }]) }
      .to raise_error(Portage::Ucp::Client::ServerError, /CSRF/)
    expect(session.search_catalog(query: "mug")["products"]).not_to be_empty
  end

  context "behind a proxy that answers the call with an HTML error page" do
    let(:rack_app) do
      mounted = Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog, registrar_options: registrar_options)
      proxy = lambda do |env|
        next mounted.call(env) unless env["REQUEST_METHOD"] == "POST"

        [502, { "content-type" => "text/html" }, ["<html>Bad Gateway</html>"]]
      end
      Rack::Builder.new { map("/ucp") { run proxy } }
    end

    it "names the endpoint and status, not a JSON parse error" do
      load_page

      expect { session.search_catalog(query: "mug") }
        .to raise_error(Portage::Ucp::Client::ServerError, /non-JSON response \(502\)/)
    end
  end

  context "with a prefix, for a page with WebMCP tools of its own" do
    let(:catalog_options) { { prefix: "acme." } }

    it "registers prefixed names, dispatches on the action, and resolves with the matching Transport prefix" do
      load_page
      prefixed = Portage::Ucp::WebMcp.connect(evaluate: ->(e) { browser.evaluate(e) }, prefix: "acme.")

      expect(prefixed.get_product(product_id: "mug")["product"]["id"]).to eq("mug")
      expect(last_rpc.dig("params", "name")).to eq("get_product")
      expect(page_json("document.modelContext.getTools()").map { |t| t["name"] }).to all(start_with("acme."))
    end
  end

  it "re-registers cleanly when the script runs again, and unregisters on request" do
    load_page
    browser.evaluate(Rack::MockRequest.new(rack_app).get("/ucp/webmcp.js").body)
    browser.evaluate("Promise.resolve().then(() => null)")

    expect(page_json("window.portageWebMcp.errors")).to eq([])
    expect(page_json("document.modelContext.getTools()").size).to eq(catalog.tools.size)

    browser.evaluate("window.portageWebMcp.unregister()")
    expect(page_json("document.modelContext.getTools()")).to eq([])
  end

  it "reports a page without WebMCP as a BridgeError, and the registrar as having nothing to register on" do
    load_page(polyfill: false)

    expect(page_json("window.portageWebMcp.reason")).to eq("no_model_context")
    expect { session.search_catalog(query: "mug") }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /no WebMCP/)
  end

  describe "parity with the in-process Loopback transport" do
    let(:catalog_options) { { authenticator: Store.permissive_authenticator } }
    let(:loopback) { Portage::Ucp::Client.for_adapter(Store.adapter, authenticator: Store.permissive_authenticator) }

    def plain(value) = JSON.parse(JSON.generate(value))

    it "returns the same documents for the same calls — one Adapter contract, two ways in" do
      load_page

      calls = [
        [:search_catalog, { query: "e", limit: 10 }],
        [:get_product, { product_id: "tee" }],
        [:create_cart, { line_items: [{ product_id: "mug", quantity: 1 }], idempotency_key: "cart" }],
        [:get_cart, { cart_id: "cart_1" }],
        [:create_checkout, { line_items: [{ product_id: "tee", quantity: 3 }], idempotency_key: "same" }]
      ]

      calls.each do |action, arguments|
        expect(session.public_send(action, **arguments)).to eq(plain(loopback.public_send(action, **arguments))),
                                                            "#{action} differed between WebMCP and Loopback"
      end
    end
  end
end

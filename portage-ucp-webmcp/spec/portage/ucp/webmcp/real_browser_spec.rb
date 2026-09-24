require "spec_helper"
require "ferrum"

# Everything round_trip_spec.rb checks with a node process standing in for a
# browser tab, but against a real, headless Chrome: registrar.js runs
# unmodified in an actual page, `document.modelContext` is Chrome's own
# WebMCP surface (polyfilled the same way an agent driving a WebMCP-less
# browser would), and every tool call is a real HTTP round trip to the Rack
# app on a real socket. Slow and needs Chrome/Chromium installed, so it's
# excluded by default — run with `REAL_BROWSER=1 bundle exec rspec
# spec/portage/ucp/webmcp/real_browser_spec.rb`.
RSpec.describe "WebMCP against a real browser", :real_browser do
  let(:catalog) { Store.catalog(only: %w[search_catalog create_cart]) }
  let(:rack_app) do
    mounted = Portage::Ucp::WebMcp::Rack::App.new(
      catalog: catalog, registrar_options: { headers: { "x-csrf-token" => Store::CSRF_TOKEN } },
      # Ferrum drives Chrome over CDP with its own network layer in front of
      # the real one; the `Origin` header a same-origin `fetch` normally
      # carries doesn't reliably reach this spec's local WEBrick harness
      # through it (confirmed independently of registrar.js: a plain fetch
      # to a debug echo handler over the same CDP session showed no `Origin`
      # either, only `Sec-Fetch-Site: same-origin`). Origin enforcement
      # itself is covered directly, with headers this spec can't control,
      # by call_endpoint_spec.rb's "browser-facing guards".
      call_options: { require_origin: false }
    )
    blank_page = ->(_env) { [200, { "content-type" => "text/html" }, ["<!doctype html><title>webmcp</title>"]] }
    Rack::Builder.new do
      map("/ucp") { run mounted }
      map("/") { run blank_page }
    end
  end
  let(:server) { LiveServer.new(rack_app) }
  let(:browser) { Ferrum::Browser.new(headless: true, timeout: 10) }
  let(:page) { browser.create_page }
  let(:bridge) { Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.ferrum(page) }
  let(:session) { Portage::Ucp::WebMcp.connect(bridge: bridge) }

  def registrar_js
    Rack::MockRequest.new(rack_app).get("/ucp/webmcp.js").body
  end

  def registered_tool_names
    page.evaluate_async("document.modelContext.getTools().then((tools) => arguments[0](tools.map((t) => t.name)))", 5)
  end

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true) # Ferrum talks to Chrome's own CDP port over HTTP
    example.run
    WebMock.disable_net_connect!
  end

  before do
    server
    # Real Chrome has no WebMCP surface yet, so give it the same
    # spec-shaped `document.modelContext` an agent driving such a browser
    # would inject, before any page script runs.
    page.command("Page.addScriptToEvaluateOnNewDocument", source: Portage::Ucp::WebMcp.polyfill_js)
    page.go_to(server.base_url)
  end

  after do
    browser.quit
    server.stop
  end

  it "registers the catalog's tools, answers a real tool call end to end, and re-registers " \
     "cleanly on a second load" do
    page.execute(registrar_js)

    expect(registered_tool_names).to match_array(%w[search_catalog create_cart])

    product = session.search_catalog(query: "mug")["products"].first
    expect(product["title"]).to eq("Enamel Mug")

    cart = session.create_cart(line_items: [{ product_id: product["id"], quantity: 1 }])
    expect(cart["id"]).to be_a(String)

    # Turbo/SPA-style reload: the script tag runs again before navigating
    # away, same as registrar.js's own re-register guard is built for.
    page.execute(registrar_js)

    expect(registered_tool_names).to match_array(%w[search_catalog create_cart])
    expect(page.evaluate("window.portageWebMcp.errors")).to eq([])

    page.evaluate_async("window.portageWebMcp.unregister().then(arguments[0])", 5)
    expect(registered_tool_names).to eq([])
  end
end

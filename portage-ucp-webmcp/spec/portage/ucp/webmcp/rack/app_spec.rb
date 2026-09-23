require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Rack::App do
  include Rack::Test::Methods

  let(:catalog) { Store.catalog(only: ["search_catalog"]) }
  let(:inner) { described_class.new(catalog: catalog) }
  let(:app) do
    mounted = inner
    Rack::Builder.new { map("/ucp") { run mounted } }
  end

  it "serves the registrar as JavaScript, pointed at the call path under its mount" do
    get "/ucp/webmcp.js"

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to start_with("application/javascript")
    expect(last_response.headers["x-content-type-options"]).to eq("nosniff")
    expect(last_response.body).to include('"endpoint":"/ucp/webmcp"')
  end

  it "routes POSTs on the call path to the CallEndpoint" do
    header "Origin", "http://example.org"
    post "/ucp/webmcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list", params: {}),
         "CONTENT_TYPE" => "application/json"

    expect(JSON.parse(last_response.body).dig("result", "tools").map { |t| t["name"] }).to eq(["search_catalog"])
  end

  it "404s anything else" do
    get "/ucp/other"

    expect(last_response.status).to eq(404)
  end

  it "answers HEAD on the script without a body and refuses POST" do
    head "/ucp/webmcp.js"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to be_empty

    post "/ucp/webmcp.js"
    expect(last_response.status).to eq(405)
  end

  context "with an explicit endpoint and custom paths" do
    let(:inner) do
      described_class.new(catalog: catalog, script_path: "/agents.js", call_path: "/agents",
                          registrar_options: { endpoint: "https://api.shop.example/ucp/agents",
                                               credentials: "include" })
    end

    it "uses them" do
      get "/ucp/agents.js"

      expect(last_response.body).to include('"endpoint":"https://api.shop.example/ucp/agents"')
      expect(last_response.body).to include('"credentials":"include"')
    end
  end
end

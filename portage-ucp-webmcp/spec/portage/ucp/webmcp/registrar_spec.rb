require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Registrar do
  let(:catalog) { Store.catalog(only: %w[search_catalog create_cart]) }
  let(:registrar) { described_class.new(catalog: catalog, endpoint: "/ucp/webmcp", headers: { "x-csrf-token" => "t" }) }

  def embedded_config(script)
    JSON.parse(script[/\}\)\((\{.*\})\);\s*\z/m, 1])
  end

  it "substitutes the catalog's tools and endpoint into the registrar script" do
    config = embedded_config(registrar.to_js)

    expect(config["endpoint"]).to eq("/ucp/webmcp")
    expect(config["credentials"]).to eq("same-origin")
    expect(config["headers"]).to eq("x-csrf-token" => "t")
    expect(config["tools"].map { |t| t["name"] }).to eq(%w[search_catalog create_cart])
    expect(registrar.to_js).not_to include(described_class::PLACEHOLDER)
  end

  it "escapes the embedded JSON so it can't close an inline <script>" do
    hostile = described_class.new(catalog: catalog, endpoint: "/x</script><script>alert(1)</script>")

    expect(hostile.to_js).not_to include("</script>")
    expect(embedded_config(hostile.to_js)["endpoint"]).to eq("/x</script><script>alert(1)</script>")
  end

  it "passes exposedTo through only when given" do
    expect(embedded_config(registrar.to_js)).not_to have_key("exposedTo")

    exposed = described_class.new(catalog: catalog, endpoint: "/e", exposed_to: ["https://agent.example"])
    expect(embedded_config(exposed.to_js)["exposedTo"]).to eq(["https://agent.example"])
  end

  it "prepends the polyfill when asked" do
    js = described_class.new(catalog: catalog, endpoint: "/e", include_polyfill: true).to_js

    expect(js).to start_with(Portage::Ucp::WebMcp.polyfill_js)
    expect(registrar.to_js).not_to include("__portageWebMcpPolyfill")
  end

  it "rejects a fetch credentials mode fetch doesn't have" do
    expect { described_class.new(catalog: catalog, endpoint: "/e", credentials: "always") }
      .to raise_error(ArgumentError, /credentials/)
  end
end

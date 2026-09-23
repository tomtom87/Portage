require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::ToolCatalog do
  subject(:catalog) { Store.catalog }

  let(:by_action) { Store.catalog(except: []).tools.to_h { |tool| [tool["action"], tool] } }

  it "derives its tools from the same Mcp::Server tools/list every other transport serves" do
    listed = catalog.server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
                    .dig(:result, :tools).map { |tool| tool[:name] }

    expect(catalog.actions).to all(satisfy { |action| listed.include?(action) })
    expect(catalog.actions).to include("search_catalog", "create_cart", "create_checkout", "get_order")
  end

  it "leaves complete_checkout out by default, since its server-side Confirmer would block the web request" do
    expect(catalog.actions).not_to include("complete_checkout")
    expect(Store.catalog(except: []).actions).to include("complete_checkout")
  end

  it "exposes only standard dev.ucp.shopping capabilities by default" do
    expect(catalog.tools.map { |t| t["capability"] }).to all(start_with("dev.ucp.shopping."))
    expect(catalog.actions).not_to include("link_identity", "save_payment_method", "delete_shopper_data",
                                           "create_payment_enrollment", "reorder")
  end

  it "widens deliberately with capabilities:" do
    widened = Store.catalog(capabilities: ->(_name) { true })

    expect(widened.actions).to include("link_identity", "reorder", "save_payment_method")
  end

  it "narrows with only: and except:" do
    expect(Store.catalog(only: %w[search_catalog get_product]).actions).to contain_exactly("search_catalog",
                                                                                           "get_product")
    expect(Store.catalog(except: ["cancel_order"]).actions).not_to include("cancel_order")
  end

  it "never exposes an action outside the capability filter, even if named in only:" do
    expect(Store.catalog(only: %w[search_catalog link_identity]).actions).to eq(["search_catalog"])
  end

  it "prefixes registered names but keeps the action the server dispatches on" do
    tool = Store.catalog(prefix: "acme.").fetch("search_catalog")

    expect(tool).to include("name" => "acme.search_catalog", "action" => "search_catalog")
  end

  it "annotates read-only, mutating and consequential tools for WebMCP" do
    expect(by_action["search_catalog"]["annotations"]).to eq("readOnlyHint" => true, "consequentialHint" => false)
    expect(by_action["create_cart"]["annotations"]).to eq("readOnlyHint" => false, "consequentialHint" => false)
    expect(by_action["complete_checkout"]["annotations"]).to eq("readOnlyHint" => false, "consequentialHint" => true)
    expect(by_action["create_cart"]["mutating"]).to be(true)
  end

  it "types the generated parameter schemas and drops idempotency_key from required" do
    schema = by_action["create_checkout"]["inputSchema"]

    expect(schema["type"]).to eq("object")
    expect(schema).not_to have_key("$schema")
    expect(schema["required"]).to eq(["line_items"])
    expect(schema.dig("properties", "line_items", "items", "required")).to eq(%w[product_id quantity])
    expect(schema.dig("properties", "idempotency_key", "type")).to eq("string")
  end

  it "gives every tool a human-readable description and title" do
    expect(by_action["search_catalog"]["description"]).to start_with("Search the store's catalog")
    expect(by_action["get_product"]["title"]).to eq("Get Product")
  end

  it "produces names valid under the WebMCP tool-name grammar" do
    expect(Store.catalog(prefix: "acme.").tools.map { |t| t["name"] }).to all(match(/\A[A-Za-z0-9_.-]{1,128}\z/))
  end

  it "answers exposes? by action name" do
    expect(catalog.exposes?("search_catalog")).to be(true)
    expect(catalog.exposes?(:search_catalog)).to be(true)
    expect(catalog.exposes?("link_identity")).to be(false)
  end
end

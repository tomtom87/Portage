require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::Client do
  let(:client) do
    described_class.new(shop_domain: "test-shop.myshopify.com", admin_access_token: "admin-token",
                        storefront_access_token: "storefront-token")
  end

  describe "#admin_query" do
    it "posts to the Admin GraphQL endpoint with the access token header" do
      stub = stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
             .with(headers: { "X-Shopify-Access-Token" => "admin-token" },
                   body: { query: "query { shop { name } }", variables: {} }.to_json)
             .to_return(status: 200, body: { data: { shop: { name: "Test Shop" } } }.to_json)

      result = client.admin_query("query { shop { name } }")

      expect(result).to eq({ "shop" => { "name" => "Test Shop" } })
      expect(stub).to have_been_requested
    end

    it "raises without an admin_access_token configured" do
      anonymous = described_class.new(shop_domain: "test-shop.myshopify.com")

      expect { anonymous.admin_query("query { shop { name } }") }.to raise_error(ArgumentError, /admin_access_token/)
    end
  end

  describe "#storefront_query" do
    it "posts to the Storefront GraphQL endpoint with the storefront token header" do
      stub_request(:post, "https://test-shop.myshopify.com/api/2026-04/graphql.json")
        .with(headers: { "X-Shopify-Storefront-Access-Token" => "storefront-token" })
        .to_return(status: 200, body: { data: { cart: nil } }.to_json)

      expect(client.storefront_query("query { cart(id: \"x\") { id } }")).to eq({ "cart" => nil })
    end
  end

  it "raises GraphqlError when the response carries top-level errors" do
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return(status: 200, body: { errors: [{ "message" => "field not found" }] }.to_json)

    expect { client.admin_query("query { nope }") }
      .to raise_error(Portage::Ucp::Shopify::GraphqlError, /field not found/)
  end

  it "raises ServerError on a bare 5xx rather than trying to parse a GraphQL body" do
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return(status: 502, body: "<html>bad gateway</html>")

    expect { client.admin_query("query { shop { name } }") }
      .to raise_error(Portage::Ucp::Shopify::ServerError)
  end

  it "retries a THROTTLED response and returns the eventual success" do
    allow(client).to receive(:sleep)
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return(
        { status: 200,
          body: { errors: [{ "message" => "Throttled", "extensions" => { "code" => "THROTTLED" } }] }.to_json },
        { status: 200, body: { data: { shop: { name: "Test Shop" } } }.to_json }
      )

    expect(client.admin_query("query { shop { name } }")).to eq({ "shop" => { "name" => "Test Shop" } })
  end

  it "does not retry a non-throttled GraphQL error" do
    stub = stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
           .to_return(status: 200, body: { errors: [{ "message" => "field not found" }] }.to_json)

    expect { client.admin_query("query { nope }") }.to raise_error(Portage::Ucp::Shopify::GraphqlError)
    expect(stub).to have_been_requested.times(1)
  end

  it "retries a bare 5xx and returns the eventual success" do
    allow(client).to receive(:sleep)
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return({ status: 503, body: "" }, { status: 200, body: { data: { shop: { name: "Test Shop" } } }.to_json })

    expect(client.admin_query("query { shop { name } }")).to eq({ "shop" => { "name" => "Test Shop" } })
  end
end

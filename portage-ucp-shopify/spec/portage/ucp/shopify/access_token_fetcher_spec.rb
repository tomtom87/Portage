require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::AccessTokenFetcher do
  let(:fetcher) do
    described_class.new(shop_domain: "test-shop.myshopify.com", client_id: "client-id",
                        client_secret: "client-secret")
  end

  it "exchanges client credentials for an admin access token" do
    stub_request(:post, "https://test-shop.myshopify.com/admin/oauth/access_token")
      .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" },
            body: { grant_type: "client_credentials", client_id: "client-id", client_secret: "client-secret" })
      .to_return(status: 200, body: { access_token: "shpat_abc123", expires_in: 3600 }.to_json)

    result = fetcher.fetch

    expect(result.access_token).to eq("shpat_abc123")
    expect(result.expires_in).to eq(3600)
  end

  it "raises when Shopify rejects the credentials" do
    stub_request(:post, "https://test-shop.myshopify.com/admin/oauth/access_token")
      .to_return(status: 401, body: { error: "invalid_client" }.to_json)

    expect { fetcher.fetch }.to raise_error(Portage::Ucp::Shopify::Error, /token exchange failed/)
  end
end

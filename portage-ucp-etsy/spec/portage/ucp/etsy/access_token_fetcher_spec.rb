require "spec_helper"

RSpec.describe Portage::Ucp::Etsy::AccessTokenFetcher do
  let(:fetcher) { described_class.new(client_id: "client-1", refresh_token: "refresh-old") }

  it "exchanges a refresh_token for a new access_token and rotated refresh_token" do
    stub_request(:post, "https://api.etsy.com/v3/public/oauth/token")
      .with(body: { grant_type: "refresh_token", client_id: "client-1", refresh_token: "refresh-old" }.to_json)
      .to_return(status: 200, body: { access_token: "acc-new", refresh_token: "refresh-new",
                                      expires_in: 3600 }.to_json)

    result = fetcher.fetch

    expect(result.access_token).to eq("acc-new")
    expect(result.refresh_token).to eq("refresh-new")
    expect(result.expires_in).to eq(3600)
  end

  it "raises when Etsy rejects the refresh_token" do
    stub_request(:post, "https://api.etsy.com/v3/public/oauth/token")
      .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    expect { fetcher.fetch }.to raise_error(Portage::Ucp::Etsy::Error, /token refresh failed/)
  end
end

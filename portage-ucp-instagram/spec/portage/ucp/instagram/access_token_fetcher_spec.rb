require "spec_helper"

RSpec.describe Portage::Ucp::Instagram::AccessTokenFetcher do
  let(:fetcher) do
    described_class.new(client_id: "client-1", client_secret: "secret-1", short_lived_token: "short-tok")
  end

  it "exchanges a short-lived token for a long-lived one" do
    stub_request(:get, "https://graph.facebook.com/v21.0/oauth/access_token")
      .with(query: { grant_type: "fb_exchange_token", client_id: "client-1", client_secret: "secret-1",
                     fb_exchange_token: "short-tok" })
      .to_return(status: 200, body: { access_token: "long-tok", token_type: "bearer",
                                      expires_in: 5_184_000 }.to_json)

    result = fetcher.fetch

    expect(result.access_token).to eq("long-tok")
    expect(result.expires_in).to eq(5_184_000)
  end

  it "raises when Meta rejects the exchange" do
    stub_request(:get, "https://graph.facebook.com/v21.0/oauth/access_token")
      .with(query: { grant_type: "fb_exchange_token", client_id: "client-1", client_secret: "secret-1",
                     fb_exchange_token: "short-tok" })
      .to_return(status: 400, body: { error: { message: "Invalid OAuth access token" } }.to_json)

    expect { fetcher.fetch }.to raise_error(Portage::Ucp::Instagram::Error, /token exchange failed/)
  end
end

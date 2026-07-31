require "spec_helper"

RSpec.describe Portage::Ucp::Wix::AccessTokenFetcher do
  let(:fetcher) do
    described_class.new(client_id: "client-id", client_secret: "client-secret", instance_id: "instance-1")
  end

  it "exchanges client credentials and an instance id for a site access token" do
    stub_request(:post, "https://www.wixapis.com/oauth2/token")
      .with(headers: { "Content-Type" => "application/json" },
            body: { grant_type: "client_credentials", client_id: "client-id", client_secret: "client-secret",
                    instance_id: "instance-1" }.to_json)
      .to_return(status: 200, body: { access_token: "OauthNG.abc123", expires_in: 3600 }.to_json)

    result = fetcher.fetch

    expect(result.access_token).to eq("OauthNG.abc123")
    expect(result.expires_in).to eq(3600)
  end

  it "raises when Wix rejects the credentials" do
    stub_request(:post, "https://www.wixapis.com/oauth2/token")
      .to_return(status: 401, body: { error: "invalid_client" }.to_json)

    expect { fetcher.fetch }.to raise_error(Portage::Ucp::Wix::Error, /token exchange failed/)
  end
end

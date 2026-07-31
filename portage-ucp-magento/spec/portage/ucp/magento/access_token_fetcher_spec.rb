require "spec_helper"

RSpec.describe Portage::Ucp::Magento::AccessTokenFetcher do
  let(:fetcher) do
    described_class.new(base_url: "https://shop.example.com", username: "admin", password: "s3cret")
  end

  it "exchanges admin credentials for a bearer token" do
    stub_request(:post, "https://shop.example.com/rest/V1/integration/admin/token")
      .with(headers: { "Content-Type" => "application/json" },
            body: { username: "admin", password: "s3cret" }.to_json)
      .to_return(status: 200, body: '"eyJhbGc_faketoken"')

    result = fetcher.fetch

    expect(result.access_token).to eq("eyJhbGc_faketoken")
  end

  it "raises when Magento rejects the credentials" do
    stub_request(:post, "https://shop.example.com/rest/V1/integration/admin/token")
      .to_return(status: 401, body: { message: "invalid credentials" }.to_json)

    expect { fetcher.fetch }.to raise_error(Portage::Ucp::Magento::Error, /token exchange failed/)
  end
end

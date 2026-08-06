require "spec_helper"
require "webmock/rspec"

RSpec.describe Portage::Ucp::Support::TokenExchange do
  test_error = Class.new(StandardError)

  let(:fetcher) do
    error_class = test_error
    Class.new do
      include Portage::Ucp::Support::TokenExchange

      define_method(:fetch) do
        exchange("https://auth.example.test/token", { grant_type: "client_credentials" }, error_class: error_class)
      end

      define_method(:refetch) do
        exchange("https://auth.example.test/token", { grant_type: "refresh_token" },
                 error_class: error_class, description: "token refresh failed")
      end
    end.new
  end

  it "posts the payload as JSON and returns the parsed body" do
    stub_request(:post, "https://auth.example.test/token").to_return(body: '{"access_token":"tok"}')
    expect(fetcher.fetch).to eq({ "access_token" => "tok" })
    expect(a_request(:post, "https://auth.example.test/token")
      .with(body: '{"grant_type":"client_credentials"}',
            headers: { "Content-Type" => "application/json" })).to have_been_made
  end

  it "parses a bare scalar body — Magento answers with just the token string" do
    stub_request(:post, "https://auth.example.test/token").to_return(body: '"bare-token"')
    expect(fetcher.fetch).to eq("bare-token")
  end

  it "raises the gem's own error on a non-2xx, quoting the body" do
    stub_request(:post, "https://auth.example.test/token").to_return(status: 401, body: '{"error":"bad_client"}')
    expect { fetcher.fetch }.to raise_error(test_error, /token exchange failed.*bad_client/)
  end

  it "takes a caller-supplied description for exchanges that aren't first-time grants" do
    stub_request(:post, "https://auth.example.test/token").to_return(status: 400, body: "{}")
    expect { fetcher.refetch }.to raise_error(test_error, /token refresh failed/)
  end
end

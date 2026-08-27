require "spec_helper"
require "webmock/rspec"

RSpec.describe Portage::Ucp::Support::HttpClient do
  test_error = Class.new(StandardError) do
    include Portage::Ucp::Support::ApiError

    private

    def api_label = "HttpTest"
  end

  let(:client_class) do
    error_class = test_error
    Class.new do
      include Portage::Ucp::Support::HttpClient

      define_method(:api_error_class) { error_class }

      def get(path) = json_request(Net::HTTP::Get, "https://example.test#{path}")
      def post(path, body) = json_request(Net::HTTP::Post, "https://example.test#{path}", body: body)
      def raw_get(path) = json_request(Net::HTTP::Get, "https://example.test#{path}", raw: true)

      def authed_get(path)
        json_request(Net::HTTP::Get, "https://example.test#{path}", headers: { "X-Auth-Token" => "secret" })
      end

      def basic_auth_get(path)
        json_request(Net::HTTP::Get, "https://example.test#{path}", basic_auth: %w[key secret])
      end
    end
  end

  let(:client) { client_class.new }

  it "parses a JSON response body" do
    stub_request(:get, "https://example.test/products").to_return(body: '{"id":1}')
    expect(client.get("/products")).to eq({ "id" => 1 })
  end

  it "sends the body as JSON with a JSON content type" do
    stub_request(:post, "https://example.test/carts").to_return(body: "{}")
    client.post("/carts", { line_items: [{ quantity: 2 }] })
    expect(a_request(:post, "https://example.test/carts")
      .with(body: '{"line_items":[{"quantity":2}]}',
            headers: { "Content-Type" => "application/json" })).to have_been_made
  end

  it "sends caller-supplied auth headers" do
    stub_request(:get, "https://example.test/orders").to_return(body: "{}")
    client.authed_get("/orders")
    expect(a_request(:get, "https://example.test/orders")
      .with(headers: { "X-Auth-Token" => "secret" })).to have_been_made
  end

  it "authorizes with HTTP Basic when given a user/password pair" do
    stub_request(:get, "https://example.test/products").with(basic_auth: %w[key secret]).to_return(body: "{}")
    expect(client.basic_auth_get("/products")).to eq({})
  end

  it "treats an empty success body as an empty hash — a 204 isn't a parse error" do
    stub_request(:get, "https://example.test/carts/1").to_return(status: 204, body: "")
    expect(client.get("/carts/1")).to eq({})
  end

  it "raises the gem's own error, carrying status and parsed body, on a non-2xx" do
    stub_request(:get, "https://example.test/products/9").to_return(status: 404, body: '{"message":"gone"}')
    expect { client.get("/products/9") }.to raise_error(test_error) { |error|
      expect([error.status, error.body]).to eq([404, { "message" => "gone" }])
    }
  end

  it "hands back the raw response when the caller needs its headers" do
    stub_request(:get, "https://example.test/cart").to_return(body: "{}", headers: { "Cart-Token" => "abc" })
    expect(client.raw_get("/cart")["Cart-Token"]).to eq("abc")
  end

  it "normalizes a 409 to Portage::Ucp::ConflictError across every HttpClient-based gem" do
    stub_request(:get, "https://example.test/carts/1").to_return(status: 409, body: '{"message":"stale version"}')
    expect { client.get("/carts/1") }.to raise_error(Portage::Ucp::ConflictError, /409/)
  end

  it "carries a Retry-After header onto the raised error for Support::Retry to read" do
    stub_request(:get, "https://example.test/products/9")
      .to_return(status: 429, body: "{}", headers: { "Retry-After" => "2" })
    expect { client.get("/products/9") }.to raise_error(test_error) { |error|
      expect(error.retry_after).to eq("2")
    }
  end

  it "requires an including client to name its error class" do
    bare = Class.new { include Portage::Ucp::Support::HttpClient }.new
    stub_request(:get, "https://example.test/x").to_return(status: 500, body: "{}")
    expect { bare.send(:json_request, Net::HTTP::Get, "https://example.test/x") }
      .to raise_error(Portage::Ucp::NotImplementedError)
  end
end

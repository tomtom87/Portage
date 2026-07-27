require "spec_helper"
require "rack/test"
require "openssl"

RSpec.describe Portage::Ucp::Rack::WebhookEndpoint do
  include Rack::Test::Methods

  let(:secret) { "shh" }
  let(:events) { [] }
  let(:manifest_order_payload) do
    { id: "order_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1", line_items: [],
      fulfillment: {}, totals: [{ type: "total", amount: 0 }], currency: "USD" }
  end

  def app
    described_class.new(secret: secret, on_order_event: ->(order) { events << order })
  end

  def signed_post(payload)
    body = JSON.generate(payload)
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/webhooks/order", body, { "HTTP_X_UCP_SIGNATURE" => signature }
  end

  it "rejects a request with no signature before parsing the body" do
    post "/webhooks/order", JSON.generate(manifest_order_payload)

    expect(last_response.status).to eq(401)
    expect(events).to be_empty
  end

  it "rejects a request with a wrong signature" do
    post "/webhooks/order", JSON.generate(manifest_order_payload), { "HTTP_X_UCP_SIGNATURE" => "nope" }

    expect(last_response.status).to eq(401)
    expect(events).to be_empty
  end

  it "verifies, normalizes to an Order, and hands off to the consumer callback" do
    signed_post(manifest_order_payload)

    expect(last_response.status).to eq(200)
    expect(events.first).to be_a(Portage::Ucp::Order)
    expect(events.first.id).to eq("order_1")
  end

  it "returns 400 for a validly-signed but malformed payload" do
    body = "not json"
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/webhooks/order", body, { "HTTP_X_UCP_SIGNATURE" => signature }

    expect(last_response.status).to eq(400)
  end

  it "rejects non-POST requests" do
    get "/webhooks/order"

    expect(last_response.status).to eq(404)
  end
end

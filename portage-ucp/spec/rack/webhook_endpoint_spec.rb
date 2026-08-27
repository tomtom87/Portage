require "spec_helper"
require "rack/test"
require "openssl"
require "stringio"

RSpec.describe Portage::Ucp::Rack::WebhookEndpoint do
  include Rack::Test::Methods

  let(:secret) { "shh" }
  let(:events) { [] }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io).tap { |l| l.formatter = proc { |_s, _t, _p, msg| "#{msg}\n" } } }
  let(:manifest_order_payload) do
    { id: "order_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1", line_items: [],
      fulfillment: {}, totals: [{ type: "total", amount: 0 }], currency: "USD" }
  end

  def app
    described_class.new(secret: secret, on_order_event: ->(order) { events << order }, logger: logger)
  end

  def logged_events
    log_io.string.lines.map { |line| JSON.parse(line) }
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

  describe "observability (§23 step 5)" do
    it "emits order_webhook_received with the order/checkout id on success" do
      signed_post(manifest_order_payload)

      event = logged_events.find { |e| e["event"] == "order_webhook_received" }
      expect(event).to include("order_id" => "order_1", "checkout_id" => "chk_1")
    end

    it "emits order_webhook_rejected for an invalid signature" do
      post "/webhooks/order", JSON.generate(manifest_order_payload), { "HTTP_X_UCP_SIGNATURE" => "nope" }

      event = logged_events.find { |e| e["event"] == "order_webhook_rejected" }
      expect(event).to include("reason" => "invalid_signature")
    end

    it "emits order_webhook_rejected for a malformed payload" do
      body = "not json"
      signature = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      post "/webhooks/order", body, { "HTTP_X_UCP_SIGNATURE" => signature }

      event = logged_events.find { |e| e["event"] == "order_webhook_rejected" }
      expect(event).to include("reason" => "bad_request")
    end
  end
end

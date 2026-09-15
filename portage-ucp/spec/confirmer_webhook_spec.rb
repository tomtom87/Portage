require "spec_helper"
require "webmock/rspec"

RSpec.describe Portage::Ucp::Confirmer::Webhook do
  def confirmer(**opts)
    described_class.new(confirm_url: "https://approver.test/confirm",
                        status_url: "https://approver.test/status",
                        poll_interval_seconds: 0.01, **opts)
  end

  def confirm!(instance)
    instance.confirm!(amount: 1000, currency: "USD", merchant: "shop.example.com", idempotency_key: "k1")
  end

  before do
    stub_request(:post, "https://approver.test/confirm").to_return(body: "{}")
  end

  it "posts the request details to the confirm URL" do
    stub_request(:get, /status/).to_return(body: '{"status":"approved"}')

    confirm!(confirmer)

    expect(a_request(:post, "https://approver.test/confirm")
      .with(body: '{"amount":1000,"currency":"USD","merchant":"shop.example.com","idempotency_key":"k1"}',
            headers: { "Content-Type" => "application/json" })).to have_been_made
  end

  it "returns approved once the status endpoint reports approved" do
    stub_request(:get, "https://approver.test/status?idempotency_key=k1")
      .to_return(body: '{"status":"pending"}').then
      .to_return(body: '{"status":"approved"}')

    expect(confirm!(confirmer(timeout_seconds: 5))).to eq({ approved: true })
  end

  it "denies when the status endpoint reports denied" do
    stub_request(:get, /status/).to_return(body: '{"status":"denied"}')

    expect { confirm!(confirmer(timeout_seconds: 5)) }.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:denied)
      expect(e.decision).to eq({ approved: false, reason: :denied, idempotency_key: "k1" })
    }
  end

  it "fails closed — denies with reason :timeout — when the status endpoint never resolves" do
    stub_request(:get, /status/).to_return(body: '{"status":"pending"}')

    expect { confirm!(confirmer(timeout_seconds: 0.03)) }.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:timeout)
      expect(e.decision).to eq({ approved: false, reason: :timeout, idempotency_key: "k1" })
    }
  end

  it "raises WebhookApiError, not ConfirmationDeniedError, when the confirm call itself fails" do
    stub_request(:post, "https://approver.test/confirm").to_return(status: 500, body: "{}")

    expect { confirm!(confirmer) }.to raise_error(Portage::Ucp::Confirmer::WebhookApiError)
  end

  it "raises WebhookApiError when the status call itself fails" do
    stub_request(:get, /status/).to_return(status: 500, body: "{}")

    expect { confirm!(confirmer(timeout_seconds: 5)) }.to raise_error(Portage::Ucp::Confirmer::WebhookApiError)
  end

  it "uses a caller-supplied wait: callback instead of polling, for push-based transports" do
    wait = ->(idempotency_key) { idempotency_key == "k1" ? "approved" : "denied" }

    expect(confirm!(confirmer(wait: wait))).to eq({ approved: true })
    expect(a_request(:get, /status/)).not_to have_been_made
  end
end

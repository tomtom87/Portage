require "spec_helper"

RSpec.describe Portage::Cli::ReconcileNotifier do
  let(:webhook) { instance_double(Portage::Cli::Notifier, call: nil) }
  let(:macos) { instance_double(Portage::Cli::MacosNotifier, call: true) }
  let(:payload) do
    { event: "checkout_reconciled", result: "complete", checkout_id: "chk_1", shop: "shop.example",
      amount: 4200, currency: "USD" }
  end

  def notifier(channels)
    described_class.new(channels: channels, webhook: webhook, macos: macos)
  end

  it "fires only the webhook by default" do
    notifier(["webhook"]).call(payload)

    expect(webhook).to have_received(:call).with(payload)
    expect(macos).not_to have_received(:call)
  end

  it "never touches the webhook when it isn't in the channel list" do
    notifier(["macos"]).call(payload)

    expect(webhook).not_to have_received(:call)
  end

  it "fires macos with a title/message built from the payload, not raw merchant text spliced in unescaped" do
    notifier(["macos"]).call(payload)

    expect(macos).to have_received(:call).with(title: "Portage checkout complete",
                                               message: "shop.example — 42.00 USD")
  end

  it "prints a terminal line" do
    output = capture_stdout { notifier(["terminal"]).call(payload) }

    expect(output).to include("chk_1: complete").and include("42.00 USD")
  end

  it "includes resolution and order in the terminal line when present" do
    output = capture_stdout do
      notifier(["terminal"]).call(payload.merge(resolution: "expired", order_id: "ord_1"))
    end

    expect(output).to include("resolution: expired").and include("order: ord_1")
  end

  it "fires every configured channel, and returns the webhook's own error" do
    allow(webhook).to receive(:call).and_return("webhook POST failed: boom")
    result = nil

    capture_stdout { result = notifier(%w[webhook macos terminal]).call(payload) }

    expect(webhook).to have_received(:call)
    expect(macos).to have_received(:call)
    expect(result).to eq("webhook POST failed: boom")
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

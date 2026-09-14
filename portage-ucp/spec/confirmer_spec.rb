require "spec_helper"
require "stringio"

RSpec.describe Portage::Ucp::Confirmer::Terminal do
  let(:output) { StringIO.new }

  def confirmer(input:, timeout_seconds: 5)
    described_class.new(timeout_seconds: timeout_seconds, input: input, output: output)
  end

  def confirm!(input)
    confirmer(input: input).confirm!(amount: 1000, currency: "USD", merchant: "shop.example.com",
                                     idempotency_key: "k1")
  end

  it "approves on an explicit y" do
    expect(confirm!(StringIO.new("y\n"))).to eq({ approved: true })
  end

  it "approves on Y, case-insensitively" do
    expect(confirm!(StringIO.new("Y\n"))).to eq({ approved: true })
  end

  it "prints the amount, currency, and merchant in the prompt" do
    confirm!(StringIO.new("y\n"))

    expect(output.string).to include("1000", "USD", "shop.example.com")
  end

  it "denies on an explicit n" do
    expect { confirm!(StringIO.new("n\n")) }.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:denied)
      expect(e.decision).to eq({ approved: false, reason: :denied, idempotency_key: "k1" })
    }
  end

  it "denies on any input that isn't y" do
    expect { confirm!(StringIO.new("sure\n")) }.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:denied)
    }
  end

  it "fails closed — denies with reason :timeout — when stdin never answers" do
    never_answers = instance_double(IO)
    allow(never_answers).to receive(:gets) { sleep(1) }

    expect do
      confirmer(input: never_answers, timeout_seconds: 0.05).confirm!(
        amount: 1000, currency: "USD", merchant: "shop.example.com", idempotency_key: "k1"
      )
    end.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:timeout)
      expect(e.decision).to eq({ approved: false, reason: :timeout, idempotency_key: "k1" })
    }
  end

  it "fails closed — denies with reason :timeout — on EOF (stdin closed out from under a headless run)" do
    expect { confirm!(StringIO.new("")) }.to raise_error(Portage::Ucp::ConfirmationDeniedError) { |e|
      expect(e.reason).to eq(:timeout)
    }
  end
end

RSpec.describe Portage::Ucp::Confirmer::AutoApprove do
  it "always approves" do
    result = described_class.new.confirm!(amount: 1000, currency: "USD", merchant: "shop.example.com",
                                          idempotency_key: "k1")

    expect(result).to eq({ approved: true })
  end
end

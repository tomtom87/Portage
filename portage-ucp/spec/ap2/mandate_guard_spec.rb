require "spec_helper"

RSpec.describe Portage::Ucp::Ap2::MandateGuard do
  def mandate(**overrides)
    Portage::Ucp::Ap2::PaymentMandate.new(
      amount: 500, currency: "USD", merchant: "shop.example.com",
      expires_at: "2099-01-01T00:00:00Z", signature: "sig", **overrides
    )
  end

  it "allows a mandate with every required field present and not expired" do
    expect { described_class.validate!(mandate) }.not_to raise_error
  end

  it "rejects a mandate missing amount" do
    expect { described_class.validate!(mandate(amount: nil)) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /amount/)
  end

  it "rejects a mandate missing signature" do
    expect { described_class.validate!(mandate(signature: nil)) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /signature/)
  end

  it "lists every missing field in one error, not just the first" do
    expect { described_class.validate!(mandate(amount: nil, merchant: nil)) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /amount.*merchant|merchant.*amount/)
  end

  it "rejects an expired mandate" do
    expect { described_class.validate!(mandate(expires_at: "2020-01-01T00:00:00Z")) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /expired/)
  end
end

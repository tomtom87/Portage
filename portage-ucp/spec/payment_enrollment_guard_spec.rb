require "spec_helper"

RSpec.describe Portage::Ucp::PaymentEnrollmentGuard do
  def enrollment(**overrides)
    Portage::Ucp::PaymentEnrollment.new(id: "penr_1", status: "pending", **overrides)
  end

  it "allows a pending enrollment with a setup_url and no payment_token" do
    expect { described_class.validate!(enrollment(status: "pending", setup_url: "https://example.com/setup")) }
      .not_to raise_error
  end

  it "rejects a pending enrollment with no setup_url" do
    expect { described_class.validate!(enrollment(status: "pending")) }
      .to raise_error(Portage::Ucp::InvalidPaymentEnrollmentError, /pending/)
  end

  it "rejects a pending enrollment that already carries a payment_token" do
    expect do
      described_class.validate!(enrollment(status: "pending", setup_url: "https://example.com/setup",
                                           payment_token: "tok"))
    end.to raise_error(Portage::Ucp::InvalidPaymentEnrollmentError, /pending/)
  end

  it "allows a complete enrollment with a payment_token and no setup_url" do
    expect { described_class.validate!(enrollment(status: "complete", payment_token: "tok")) }.not_to raise_error
  end

  it "rejects a complete enrollment with no payment_token" do
    expect { described_class.validate!(enrollment(status: "complete")) }
      .to raise_error(Portage::Ucp::InvalidPaymentEnrollmentError, /complete/)
  end

  it "rejects a complete enrollment that still carries a setup_url" do
    expect do
      described_class.validate!(enrollment(status: "complete", payment_token: "tok",
                                           setup_url: "https://example.com/setup"))
    end.to raise_error(Portage::Ucp::InvalidPaymentEnrollmentError, /complete/)
  end

  it "rejects an unknown status" do
    expect { described_class.validate!(enrollment(status: "banana")) }
      .to raise_error(Portage::Ucp::InvalidPaymentEnrollmentError, /banana/)
  end
end

require "spec_helper"

RSpec.describe Portage::Ucp::PaymentTokenGuard do
  it "rejects a Luhn-valid card number" do
    expect { described_class.validate!("4111111111111111") }.to raise_error(Portage::Ucp::RawPanRejectedError)
  end

  it "allows an opaque tokenized credential" do
    expect { described_class.validate!("tok_live_9f8a7b6c5d4e") }.not_to raise_error
  end

  it "allows a digit-only string that fails the Luhn check" do
    expect { described_class.validate!("1234567890123456") }.not_to raise_error
  end

  it "allows a digit-only string outside PAN length bounds" do
    expect { described_class.validate!("4111111111") }.not_to raise_error
  end

  it "allows nil (no payment_token given)" do
    expect { described_class.validate!(nil) }.not_to raise_error
  end
end

require "spec_helper"
require "support/signing_helper"

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

  it "skips cryptographic verification when no trusted_keys are given (shape-only, unchanged posture)" do
    expect { described_class.validate!(mandate(signature: "not-even-base64")) }.not_to raise_error
  end

  it "raises when require_signature is true but trusted_keys resolves to nil" do
    expect { described_class.validate!(mandate, require_signature: true) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /signature verification is required/)
  end

  describe "with trusted_keys" do
    let(:ec_key) { SigningHelper.keypair }
    let(:jwk) { SigningHelper.jwk(ec_key, kid: "issuer-1") }

    def signed_mandate(**overrides)
      unsigned = mandate(kid: "issuer-1", signature: nil, **overrides)
      raw = SigningHelper.der_to_raw(ec_key.sign("SHA256", unsigned.signing_payload), 32)
      unsigned.with(signature: Base64.strict_encode64(raw))
    end

    it "passes a validly signed mandate" do
      expect { described_class.validate!(signed_mandate, trusted_keys: [jwk]) }.not_to raise_error
    end

    it "rejects a mandate whose signature doesn't verify against the trust anchor" do
      tampered = signed_mandate.with(amount: 999_999)
      expect { described_class.validate!(tampered, trusted_keys: [jwk]) }
        .to raise_error(Portage::Ucp::InvalidMandateError, /does not verify/)
    end

    it "does not raise the require_signature error when trusted_keys are given" do
      expect { described_class.validate!(signed_mandate, trusted_keys: [jwk], require_signature: true) }
        .not_to raise_error
    end
  end
end

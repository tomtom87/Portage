require "spec_helper"
require "support/signing_helper"

RSpec.describe Portage::Ucp::Ap2::MandateSignature do
  let(:ec_key) { SigningHelper.keypair }
  let(:jwk) { SigningHelper.jwk(ec_key, kid: "issuer-1") }
  let(:trusted_keys) { [jwk] }

  def mandate(**overrides)
    Portage::Ucp::Ap2::PaymentMandate.new(
      amount: 500, currency: "USD", merchant: "shop.example.com",
      expires_at: "2099-01-01T00:00:00Z", kid: "issuer-1", signature: nil, **overrides
    )
  end

  def signed_mandate(**overrides)
    unsigned = mandate(**overrides)
    raw = SigningHelper.der_to_raw(ec_key.sign("SHA256", unsigned.signing_payload), 32)
    unsigned.with(signature: Base64.strict_encode64(raw))
  end

  it "verifies a validly signed mandate" do
    expect(described_class.verify!(signed_mandate, trusted_keys: trusted_keys)).to eq(true)
  end

  it "verifies against a P-384 key" do
    ec_key384 = SigningHelper.keypair("secp384r1")
    jwk384 = SigningHelper.jwk(ec_key384, kid: "issuer-384", crv: "P-384")
    unsigned = mandate(kid: "issuer-384")
    raw = SigningHelper.der_to_raw(ec_key384.sign("SHA384", unsigned.signing_payload), 48)
    signed = unsigned.with(signature: Base64.strict_encode64(raw))

    expect(described_class.verify!(signed, trusted_keys: [jwk384])).to eq(true)
  end

  it "rejects a mandate with no kid" do
    expect { described_class.verify!(signed_mandate(kid: nil), trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /kid/)
  end

  it "rejects a mandate whose kid isn't in the trusted set" do
    expect { described_class.verify!(signed_mandate(kid: "unknown"), trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /no trusted key/)
  end

  it "rejects a mandate whose signature was made over different fields (tampered amount)" do
    signed = signed_mandate
    tampered = signed.with(amount: 999_999)
    expect { described_class.verify!(tampered, trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /does not verify/)
  end

  it "rejects a mandate signed by a different key than the trusted one" do
    other_key = SigningHelper.keypair
    unsigned = mandate
    raw = SigningHelper.der_to_raw(other_key.sign("SHA256", unsigned.signing_payload), 32)
    forged = unsigned.with(signature: Base64.strict_encode64(raw))

    expect { described_class.verify!(forged, trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /does not verify/)
  end

  it "rejects a mandate with corrupted signature bytes" do
    signed = signed_mandate.with(signature: Base64.strict_encode64("x" * 64))
    expect { described_class.verify!(signed, trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /does not verify/)
  end

  it "rejects a mandate signature that isn't valid base64" do
    signed = signed_mandate.with(signature: "not base64!!")
    expect { described_class.verify!(signed, trusted_keys: trusted_keys) }
      .to raise_error(Portage::Ucp::InvalidMandateError, /base64/)
  end

  it "resolves trusted_keys via a callable resolver instead of a static array" do
    resolver = ->(kid) { kid == "issuer-1" ? jwk : nil }
    expect(described_class.verify!(signed_mandate, trusted_keys: resolver)).to eq(true)
  end
end

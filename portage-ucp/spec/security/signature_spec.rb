require "spec_helper"
require "support/signing_helper"
require "openssl"
require "base64"

RSpec.describe Portage::Ucp::Security::Signature do
  let(:ec_key) { SigningHelper.keypair }
  let(:jwk) { SigningHelper.jwk(ec_key, kid: "k1") }
  let(:trusted_keys) { [jwk] }
  let(:body) { JSON.generate(action: "create_checkout") }

  def signed_headers(**overrides)
    SigningHelper.sign(ec_key: ec_key, kid: "k1", method: "POST", authority: "shop.example.com",
                       path: "/mcp", headers: { "idempotency-key" => "idem-1" }, body: body, **overrides)
  end

  def verify(headers, **overrides)
    described_class.verify!(method: "POST", authority: "shop.example.com", path: "/mcp", headers: headers,
                            body: body, trusted_keys: trusted_keys, **overrides)
  end

  it "verifies a validly signed request" do
    expect(verify(signed_headers)).to eq(verified: true, keyid: "k1")
  end

  it "verifies against a P-384 key" do
    ec_key384 = SigningHelper.keypair("secp384r1")
    jwk384 = SigningHelper.jwk(ec_key384, kid: "k384", crv: "P-384")
    headers = SigningHelper.sign(ec_key: ec_key384, kid: "k384", method: "POST", authority: "shop.example.com",
                                 path: "/mcp", headers: { "idempotency-key" => "idem-1" }, body: body,
                                 digest_name: "SHA384", coord: 48)

    expect(described_class.verify!(method: "POST", authority: "shop.example.com", path: "/mcp", headers: headers,
                                   body: body, trusted_keys: [jwk384])).to eq(verified: true, keyid: "k384")
  end

  it "raises MissingSignatureError with no signature headers at all" do
    expect { verify({}) }.to raise_error(Portage::Ucp::Security::MissingSignatureError)
  end

  it "raises MissingSignatureError with Signature-Input but no Signature" do
    headers = signed_headers.except("signature")
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::MissingSignatureError)
  end

  it "raises UnknownKeyError for a keyid not in the trusted set" do
    headers = signed_headers
    headers["signature-input"] = headers["signature-input"].sub('keyid="k1"', 'keyid="unknown"')
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::UnknownKeyError)
  end

  it "raises InvalidSignatureError when the body is tampered with after signing" do
    headers = signed_headers
    expect do
      described_class.verify!(method: "POST", authority: "shop.example.com", path: "/mcp", headers: headers,
                              body: JSON.generate(action: "delete_everything"), trusted_keys: trusted_keys)
    end.to raise_error(Portage::Ucp::Security::DigestMismatchError)
  end

  it "raises InvalidSignatureError when a covered component's actual value differs from what was signed" do
    headers = signed_headers
    expect do
      described_class.verify!(method: "POST", authority: "attacker.example.com", path: "/mcp", headers: headers,
                              body: body, trusted_keys: trusted_keys)
    end.to raise_error(Portage::Ucp::Security::InvalidSignatureError)
  end

  it "raises InvalidSignatureError when the raw signature bytes are corrupted" do
    headers = signed_headers
    headers["signature"] = "sig1=:#{Base64.strict_encode64('x' * 64)}:"
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::InvalidSignatureError)
  end

  it "raises MalformedSignatureError when the signature doesn't cover a required component" do
    headers = signed_headers(components: %w[@method @authority @path])
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::MalformedSignatureError)
  end

  it "raises MalformedSignatureError when a body is present but content-digest isn't covered" do
    headers = signed_headers(components: %w[@method @authority @path idempotency-key])
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::MalformedSignatureError)
  end

  it "raises DigestMismatchError when content-digest doesn't match the body" do
    headers = signed_headers(components: %w[@method @authority @path idempotency-key content-digest])
    headers["content-digest"] = "sha-256=:#{Base64.strict_encode64('0' * 32)}:"
    expect { verify(headers) }.to raise_error(Portage::Ucp::Security::DigestMismatchError)
  end

  it "raises StaleSignatureError when the signature is older than max_age" do
    headers = signed_headers(created: Time.now.to_i - 3600)
    expect { verify(headers, max_age: 300) }.to raise_error(Portage::Ucp::Security::StaleSignatureError)
  end

  it "does not enforce freshness when max_age is nil" do
    headers = signed_headers(created: Time.now.to_i - 3600)
    expect(verify(headers, max_age: nil)).to eq(verified: true, keyid: "k1")
  end

  it "resolves trusted_keys via a callable resolver instead of a static array" do
    resolver = ->(kid) { kid == "k1" ? jwk : nil }
    result = described_class.verify!(method: "POST", authority: "shop.example.com", path: "/mcp",
                                     headers: signed_headers, body: body, trusted_keys: resolver)
    expect(result).to eq(verified: true, keyid: "k1")
  end
end

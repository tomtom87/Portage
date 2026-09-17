require "spec_helper"
require "tmpdir"
require "openssl"
require "base64"
require "digest"

RSpec.describe Portage::Cli::Generate::AgentProfile do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "writes a profile document shaped per the UCP agent-profile schema — " \
     "signing_keys as a root sibling of ucp, not nested inside it" do
    described_class.generate(out: "profile.json", key_out: "key.pem")

    doc = JSON.parse(File.read("profile.json"))
    expect(doc.keys).to contain_exactly("ucp", "signing_keys")
    expect(doc["ucp"]).to eq(
      "version" => Portage::Ucp::Manifest::UCP_VERSION,
      "services" => {},
      "capabilities" => {},
      "payment_handlers" => {}
    )
    expect(doc["signing_keys"].size).to eq(1)
  end

  it "publishes a JWK whose kid is the RFC 7638 thumbprint of its own key material" do
    described_class.generate(out: "profile.json", key_out: "key.pem")

    jwk = JSON.parse(File.read("profile.json"))["signing_keys"].first
    expect(jwk).to include("kty" => "EC", "crv" => "P-256", "use" => "sig", "alg" => "ES256")
    expect(jwk["kid"]).to eq(
      Base64.urlsafe_encode64(
        Digest::SHA256.digest(JSON.generate({ "crv" => "P-256", "kty" => "EC", "x" => jwk["x"], "y" => jwk["y"] })),
        padding: false
      )
    )
  end

  it "writes a private key that round-trips as a valid P-256 key, 0600" do
    described_class.generate(out: "profile.json", key_out: "key.pem")

    pkey = OpenSSL::PKey::EC.new(File.read("key.pem"))
    expect(pkey.group.curve_name).to eq("prime256v1")
    expect(File.stat("key.pem").mode & 0o777).to eq(0o600)
  end

  it "replaces any existing signing_keys by default (no rotate)" do
    described_class.generate(out: "profile.json", key_out: "key1.pem")
    old_kid = JSON.parse(File.read("profile.json"))["signing_keys"].first["kid"]

    described_class.generate(out: "profile.json", key_out: "key2.pem")
    kids = JSON.parse(File.read("profile.json"))["signing_keys"].map { |k| k["kid"] }

    expect(kids).to eq([JSON.parse(File.read("profile.json"))["signing_keys"].first["kid"]])
    expect(kids).not_to include(old_kid)
  end

  it "keeps every previously published key when rotating, and adds a new one" do
    described_class.generate(out: "profile.json", key_out: "key1.pem")
    old_kid = JSON.parse(File.read("profile.json"))["signing_keys"].first["kid"]

    result = described_class.generate(out: "profile.json", key_out: "key2.pem", rotate: true)
    kids = JSON.parse(File.read("profile.json"))["signing_keys"].map { |k| k["kid"] }

    expect(kids).to contain_exactly(old_kid, result[:kid])
  end

  it "returns the paths written and the new key's kid" do
    result = described_class.generate(out: "profile.json", key_out: "key.pem")

    expect(result).to eq(
      profile_path: "profile.json",
      private_key_path: "key.pem",
      kid: JSON.parse(File.read("profile.json"))["signing_keys"].first["kid"]
    )
  end

  it "creates intermediate directories for both the profile and the key" do
    described_class.generate(out: "nested/dir/profile.json", key_out: "other/dir/key.pem")

    expect(File.exist?("nested/dir/profile.json")).to be true
    expect(File.exist?("other/dir/key.pem")).to be true
  end
end

require "spec_helper"
require "support/signing_helper"
require "rack/test"
require "openssl"
require "base64"
require "stringio"

RSpec.describe Portage::Ucp::Rack::SignatureVerification do
  include Rack::Test::Methods

  let(:ec_key) { SigningHelper.keypair }
  let(:jwk) { SigningHelper.jwk(ec_key, kid: "k1") }
  let(:downstream_calls) { [] }
  let(:downstream) do
    calls = downstream_calls
    lambda { |env|
      calls << env["rack.input"].read
      [200, { "content-type" => "application/json" }, [JSON.generate(ok: true)]]
    }
  end
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io).tap { |l| l.formatter = proc { |_s, _t, _p, msg| "#{msg}\n" } } }

  def app
    described_class.new(downstream, trusted_keys: [jwk], logger: logger)
  end

  # Rack::Test posts a body string directly; the signed headers are built
  # against the same request-line/body Signature-Verification will see, then
  # translated into the Rack env's HTTP_* naming.
  def signed_post(path, body)
    signed = SigningHelper.sign(ec_key: ec_key, kid: "k1", method: "POST", authority: "example.org", path: path,
                                headers: { "idempotency-key" => "idem-1" }, body: body)
    post path, body, {
      "HTTP_SIGNATURE_INPUT" => signed["signature-input"], "HTTP_SIGNATURE" => signed["signature"],
      "HTTP_IDEMPOTENCY_KEY" => "idem-1", "HTTP_CONTENT_DIGEST" => signed["content-digest"]
    }
  end

  it "passes a validly signed request through to the wrapped app" do
    signed_post("/mcp", JSON.generate(tool: "create_checkout"))

    expect(last_response.status).to eq(200)
    expect(downstream_calls).to eq([JSON.generate(tool: "create_checkout")])
  end

  it "rejects a request with no signature before it reaches the wrapped app" do
    post "/mcp", JSON.generate(tool: "create_checkout")

    expect(last_response.status).to eq(401)
    expect(downstream_calls).to be_empty
  end

  it "rejects a request whose body was altered after signing" do
    original_body = JSON.generate(tool: "create_checkout")
    signed = SigningHelper.sign(ec_key: ec_key, kid: "k1", method: "POST", authority: "example.org", path: "/mcp",
                                headers: { "idempotency-key" => "idem-1" }, body: original_body)

    post "/mcp", JSON.generate(tool: "delete_everything"), {
      "HTTP_SIGNATURE_INPUT" => signed["signature-input"], "HTTP_SIGNATURE" => signed["signature"],
      "HTTP_IDEMPOTENCY_KEY" => "idem-1", "HTTP_CONTENT_DIGEST" => signed["content-digest"]
    }

    expect(last_response.status).to eq(401)
    expect(downstream_calls).to be_empty
  end

  it "logs the rejection reason" do
    post "/mcp", JSON.generate(tool: "create_checkout")

    events = log_io.string.lines.map { |line| JSON.parse(line) }
    event = events.find { |e| e["event"] == "signature_verification_rejected" }
    expect(event).to include("reason" => "MissingSignatureError")
  end
end

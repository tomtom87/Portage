require "spec_helper"
require "tmpdir"

class FakePaymentBackend
  def initialize
    @store = {}
  end

  def write(id, token) = @store[id] = token
  def read(id) = @store[id]
  def delete(id) = @store.delete(id)
end

RSpec.describe Portage::Cli::PaymentMethods do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "payment_methods.json")
      example.run
    end
  end

  let(:backend) { FakePaymentBackend.new }
  let(:payment_methods) { described_class.new(path: @path, backend: backend) }

  def enroll!(label: "Visa")
    payment_methods.enroll("https://shop.example", label: label, poll_interval: 0, sleeper: ->(_s) {}) { nil }
  end

  describe "#detect_backend" do
    it "falls back to EnvBackend when no keychain/secret-tool is available" do
      allow(described_class::KeychainBackend).to receive(:available?).and_return(false)
      allow(described_class::SecretServiceBackend).to receive(:available?).and_return(false)

      expect(described_class.detect_backend).to be_a(described_class::EnvBackend)
    end

    it "prefers KeychainBackend when available" do
      allow(described_class::KeychainBackend).to receive(:available?).and_return(true)

      expect(described_class.detect_backend).to be_a(described_class::KeychainBackend)
    end
  end

  describe "headless (EnvBackend)" do
    let(:backend) { described_class::EnvBackend.new }

    it "#default reads straight from PORTAGE_PAYMENT_TOKEN, bypassing metadata entirely" do
      with_env("PORTAGE_PAYMENT_TOKEN" => "tok_env") do
        expect(payment_methods.default).to eq("tok_env")
      end
    end

    it "#list is always empty — there's nothing local to track" do
      expect(payment_methods.list).to eq([])
    end

    it "#enroll refuses — headless mode has no local storage to enroll into" do
      expect { payment_methods.enroll("https://shop.example") }
        .to raise_error(described_class::NotSupportedError, /PORTAGE_PAYMENT_TOKEN/)
    end
  end

  describe "#enroll" do
    let(:pending_enrollment) { { "id" => "penr_1", "status" => "pending", "setup_url" => "https://gw.example/setup" } }
    let(:completed_enrollment) { { "id" => "penr_1", "status" => "complete", "payment_token" => "reftok_abc" } }

    def fake_session(advertises: true, create: pending_enrollment, polls: [completed_enrollment])
      session = instance_double(Portage::Ucp::Client::Session, advertises?: advertises,
                                                               create_payment_enrollment: create)
      allow(session).to receive(:get_payment_enrollment).and_return(*polls)
      session
    end

    it "yields the setup_url before polling, then stores the token once complete" do
      session = fake_session
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      yielded = nil

      result = payment_methods.enroll("https://shop.example", label: "Visa", poll_interval: 0,
                                                              sleeper: ->(_s) {}) { |url| yielded = url }

      expect(yielded).to eq("https://gw.example/setup")
      expect(result[:status]).to eq("complete")
      expect(payment_methods.list.first["label"]).to eq("Visa")
      expect(payment_methods.default).to eq("reftok_abc")
    end

    it "marks the first enrollment as the default" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(fake_session)

      enroll!

      expect(payment_methods.list.first["default"]).to be true
    end

    it "returns pending (without storing anything) when the timeout elapses first" do
      session = fake_session(polls: [pending_enrollment])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      result = payment_methods.enroll("https://shop.example", poll_interval: 0, timeout: 0, sleeper: ->(_s) {}) { nil }

      expect(result).to eq(status: "pending", setup_url: "https://gw.example/setup", id: "penr_1")
      expect(payment_methods.list).to eq([])
    end

    it "reports unsupported when discovery finds nothing" do
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(Portage::Ucp::Client::DiscoveryError, "nope")
      stub_request(:get, "https://shop.example/").to_return(status: 404)

      result = payment_methods.enroll("https://shop.example", poll_interval: 0, sleeper: ->(_s) {}) { nil }

      expect(result).to eq(status: "unsupported")
    end

    it "reports unsupported when the store doesn't advertise payment enrollment" do
      session = fake_session(advertises: false)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      result = payment_methods.enroll("https://shop.example", poll_interval: 0, sleeper: ->(_s) {}) { nil }

      expect(result).to eq(status: "unsupported")
    end
  end

  describe "#make_default / #remove / #revoke / #freeze_method" do
    before do
      completed = { "id" => "penr_1", "status" => "complete", "payment_token" => "tok_a" }
      session = instance_double(Portage::Ucp::Client::Session, advertises?: true, create_payment_enrollment: completed)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      enroll!(label: "Visa")
    end

    let(:id) { payment_methods.list.first["id"] }

    it "raises UnknownMethodError for an id that was never enrolled" do
      expect { payment_methods.make_default("nope") }.to raise_error(described_class::UnknownMethodError)
    end

    it "#freeze_method blocks #default without deleting the backend secret or metadata" do
      payment_methods.freeze_method(id)

      expect(payment_methods.default).to be_nil
      expect(payment_methods.list.first["frozen"]).to be true
      expect(backend.read(id)).to eq("tok_a")
    end

    it "#remove deletes both the metadata entry and the backend secret" do
      payment_methods.remove(id)

      expect(payment_methods.list).to eq([])
      expect(backend.read(id)).to be_nil
    end

    it "#revoke is the same hard delete as #remove" do
      payment_methods.revoke(id)

      expect(payment_methods.list).to eq([])
      expect(backend.read(id)).to be_nil
    end
  end
end

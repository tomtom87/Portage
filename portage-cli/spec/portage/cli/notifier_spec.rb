require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Notifier do
  # `Config.new(data: {})` alone still defaults `path:` to the real
  # ~/.portage/config.json — any `#set` call in these examples would write
  # to the developer's actual config file, not a fixture. Pointing every
  # `Config` at a throwaway path keeps that write local to the example.
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.json")
      example.run
    end
  end

  let(:config) { Portage::Cli::Config.new(path: @config_path, data: {}) }
  let(:webhook_url) { "https://hooks.example/x" }
  let(:payload) { { event: "checkout_handoff", reason: "requires_escalation", checkout_url: "https://shop.example/c" } }

  describe "#webhook_url precedence" do
    it "is nil when nothing is configured" do
      expect(described_class.new(config: config).webhook_url).to be_nil
    end

    it "reads config.json when set" do
      config.set("notify_webhook_url", webhook_url)

      expect(described_class.new(config: config).webhook_url).to eq(webhook_url)
    end

    it "prefers the env var over config.json" do
      config.set("notify_webhook_url", webhook_url)

      with_env("PORTAGE_NOTIFY_WEBHOOK_URL" => "https://hooks.example/env") do
        expect(described_class.new(config: config).webhook_url).to eq("https://hooks.example/env")
      end
    end

    it "prefers an explicit override over both the env var and config.json" do
      config.set("notify_webhook_url", "https://hooks.example/config")

      with_env("PORTAGE_NOTIFY_WEBHOOK_URL" => "https://hooks.example/env") do
        expect(described_class.new(webhook_url: webhook_url, config: config).webhook_url).to eq(webhook_url)
      end
    end
  end

  describe "#call" do
    it "never attempts a request when disabled (no webhook configured)" do
      notifier = described_class.new(config: config)

      notifier.call(payload)

      expect(a_request(:post, /.*/)).not_to have_been_made
    end

    it "posts the payload as JSON and returns nil on success" do
      stub = stub_request(:post, webhook_url)
             .with(body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: "{}")

      result = described_class.new(webhook_url: webhook_url, config: config).call(payload)

      expect(result).to be_nil
      expect(stub).to have_been_requested
    end

    it "doesn't raise on a failed POST, and returns the failure message" do
      stub_request(:post, webhook_url).to_return(status: 500, body: '{"error":"boom"}')

      result = described_class.new(webhook_url: webhook_url, config: config).call(payload)

      expect(result).to include("500")
    end

    it "doesn't raise when the request itself can't be made, and returns the failure message" do
      stub_request(:post, webhook_url).to_raise(SocketError.new("getaddrinfo failed"))

      result = described_class.new(webhook_url: webhook_url, config: config).call(payload)

      expect(result).to include("getaddrinfo failed")
    end
  end
end

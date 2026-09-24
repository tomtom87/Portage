# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md: four of the nine raw
# `Net::HTTP.start(uri.host, uri.port, ...)` call sites live in portage-cli
# (Buy#fetch_homepage, SearchBackends.request, PaymentMethods#fetch_homepage,
# Notifier#post). None pass an explicit `p_addr`, so Net::HTTP's own
# `:ENV` default decides whether an env proxy is used. These specs run a
# real local CONNECT-capable proxy (spec/support/local_proxy.rb) and assert
# each site actually reaches it, so the Phase 1 Support::Connection refactor
# can't silently regress today's (accidental) env-proxy support.
#
# WebMock's global `disable_net_connect!` (spec_helper.rb) would otherwise
# block even this loopback traffic, so it's loosened to allow localhost only
# for the duration of these examples.
RSpec.describe "Phase 0 env-proxy support (portage-cli)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    # WebMock intercepts by *target* host, not by the proxy it would
    # actually dial -- allow_localhost: true doesn't cover "target is
    # shop.example.invalid, reached via a proxy on 127.0.0.1". These specs
    # never touch the real network either way: the targets are all
    # RFC 2606 .invalid hostnames that can't resolve, and the only real
    # socket opened is a loopback one to LocalProxy.
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:proxy) { LocalProxy.new }

  after { proxy.stop }

  describe "Buy#fetch_homepage" do
    it "routes through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      buy = Portage::Cli::Buy.new(url: "https://shop.example.invalid", query: "hoodie")

      buy.send(:fetch_homepage, URI("https://shop.example.invalid/"))

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end

  describe "SearchBackends.request" do
    it "routes through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect { Portage::Cli::SearchBackends.send(:request, URI("https://search.example.invalid/q"), {}) }
        .to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT search.example.invalid:443 HTTP/1.1")
    end
  end

  describe "PaymentMethods#fetch_homepage" do
    it "routes through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      methods = Portage::Cli::PaymentMethods.new(path: File.join(Dir.mktmpdir, "payment_methods.json"),
                                                 backend: Object.new)

      methods.send(:fetch_homepage, URI("https://shop.example.invalid/"))

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end

  describe "Notifier#post" do
    it "routes through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      notifier.call({ event: "dead_end" })

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT hooks.example.invalid:443 HTTP/1.1")
    end

    it "is not reached at all when only https_proxy is set (the confirmed gap)" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      Timeout.timeout(3) { notifier.call({ event: "dead_end" }) }

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end

  describe "credentials and no_proxy, checked once against Notifier (representative of all four sites)" do
    it "sends Proxy-Authorization from user:pass in the proxy URL" do
      ENV["http_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      notifier.call({ event: "dead_end" })

      auth = proxy.last_request.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    end

    it "honours no_proxy for the target host" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      ENV["no_proxy"] = "hooks.example.invalid"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      Timeout.timeout(3) { notifier.call({ event: "dead_end" }) }

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end
end

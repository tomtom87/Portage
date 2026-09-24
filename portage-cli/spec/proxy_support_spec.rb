# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md documented a real gap: four of the
# nine raw `Net::HTTP.start(uri.host, uri.port, ...)` call sites lived in
# portage-cli (Buy#fetch_homepage, SearchBackends.request,
# PaymentMethods#fetch_homepage, Notifier#post), none passing an explicit
# `p_addr`, so Net::HTTP's own `:ENV` proxy default decided whether an env
# proxy was used -- and that default reads *only* `http_proxy`/`HTTP_PROXY`,
# for both http and https targets, because `Net::HTTP#proxy_uri` hardcodes
# its env-lookup scheme to "http" regardless of `use_ssl?` (see
# docs/design-log.md #44).
#
# Phase 1 replaced all four raw Net::HTTP.start calls with
# Portage::Ucp::Support::Connection.start (route: :store for Buy/Payment
# Methods' homepage fetches, :search for SearchBackends, :notify for
# Notifier), which resolves the env proxy itself instead of leaving
# Net::HTTP's `:ENV` default in place -- and, unlike Net::HTTP, actually
# reads HTTPS_PROXY/https_proxy for an https:// target. These specs assert
# the *fixed* behavior directly against a real local proxy, closing the gap
# Phase 0 could only document.
#
# WebMock's global `disable_net_connect!` (spec_helper.rb) would otherwise
# block even this loopback traffic, so it's loosened to allow localhost only
# for the duration of these examples.
RSpec.describe "Phase 1 env-proxy support via Support::Connection (portage-cli)" do
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

  describe "Buy#fetch_homepage (route :store)" do
    it "closes docs/design-log.md #44's gap: routes an https target through HTTPS_PROXY/https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      buy = Portage::Cli::Buy.new(url: "https://shop.example.invalid", query: "hoodie")

      buy.send(:fetch_homepage, URI("https://shop.example.invalid/"))

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end

    it "no longer reads http_proxy alone for an https:// target" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      buy = Portage::Cli::Buy.new(url: "https://shop.example.invalid", query: "hoodie")

      Timeout.timeout(3) { buy.send(:fetch_homepage, URI("https://shop.example.invalid/")) }

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end

  describe "SearchBackends.request (route :search)" do
    it "closes docs/design-log.md #44's gap: routes an https target through HTTPS_PROXY/https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect { Portage::Cli::SearchBackends.send(:request, URI("https://search.example.invalid/q"), {}) }
        .to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT search.example.invalid:443 HTTP/1.1")
    end
  end

  describe "PaymentMethods#fetch_homepage (route :payment)" do
    it "closes docs/design-log.md #44's gap: routes an https target through HTTPS_PROXY/https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      methods = Portage::Cli::PaymentMethods.new(path: File.join(Dir.mktmpdir, "payment_methods.json"),
                                                 backend: Object.new)

      methods.send(:fetch_homepage, URI("https://shop.example.invalid/"))

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end

  describe "Notifier#post (route :notify)" do
    it "closes docs/design-log.md #44's gap: routes an https webhook through HTTPS_PROXY/https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      notifier.call({ event: "dead_end" })

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT hooks.example.invalid:443 HTTP/1.1")
    end

    it "is no longer reached when only http_proxy is set for an https:// webhook (gap closed the other way too)" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      Timeout.timeout(3) { notifier.call({ event: "dead_end" }) }

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end

  describe "credentials and no_proxy, checked once against Notifier (representative of all four sites)" do
    it "sends Proxy-Authorization from user:pass in the https_proxy URL" do
      ENV["https_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      notifier.call({ event: "dead_end" })

      auth = proxy.last_request.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    end

    it "honours no_proxy for the target host" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      ENV["no_proxy"] = "hooks.example.invalid"
      notifier = Portage::Cli::Notifier.new(webhook_url: "https://hooks.example.invalid/notify")

      Timeout.timeout(3) { notifier.call({ event: "dead_end" }) }

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end
end

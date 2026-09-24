# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "portage/ucp/support/http_client"
require "portage/ucp/support/token_exchange"
require "portage/ucp/check"
require "base64"
require "timeout"
require "webmock/rspec" # other spec files in this gem require it too, which disables net connect process-wide

# Phase 0 of docs/plans/proxy-support.md: Support::HttpClient, Check and
# Support::TokenExchange are three of the nine raw `Net::HTTP.start(uri.host,
# uri.port, ...)` call sites the plan lists. None of them pass an explicit
# `p_addr`, so Net::HTTP's own default (`:ENV`) is what decides whether an
# env proxy is used -- these specs lock that default in against a real local
# proxy so a future refactor (Phase 1's Support::Connection) can't silently
# regress it.
#
# Confirmed here (see docs/proxy.md for the full write-up): only
# `http_proxy`/`HTTP_PROXY` is ever consulted for an env proxy, for *both*
# http and https targets -- `https_proxy`/`HTTPS_PROXY` is never read by
# Net::HTTP's `:ENV` proxy mode (`Net::HTTP#proxy_uri` hardcodes the lookup
# scheme to "http" regardless of `use_ssl?`). That is a genuine gap against
# the common HTTPS_PROXY convention, not a mistake in these specs.
class TestHttpClient
  include Portage::Ucp::Support::HttpClient

  public :json_request

  def api_error_class = StandardError
end

class TestTokenExchange
  include Portage::Ucp::Support::TokenExchange

  public :exchange
end

RSpec.describe "Phase 0 env-proxy support (portage-ucp)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    # WebMock intercepts by *target* host, not by the (loopback) proxy a
    # request actually dials -- these specs never touch the real network
    # either way: targets are RFC 2606 .invalid hostnames that can't
    # resolve, and the only real socket opened is to LocalProxy.
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:proxy) { LocalProxy.new }

  after { proxy.stop }

  describe Portage::Ucp::Support::HttpClient do
    it "routes an https request through http_proxy (Net::HTTP never reads https_proxy)" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect do
        TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders"))
      end.to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end

    it "is not reached at all when only https_proxy is set (the confirmed gap)" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect do
        Timeout.timeout(2) do
          TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders"))
        end
      end.to raise_error(StandardError) # real DNS failure for the *.invalid host, not a proxy error

      expect(proxy.last_request(timeout: 1)).to be_nil
    end

    it "sends Proxy-Authorization from user:pass in the proxy URL" do
      ENV["http_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

      expect { TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders")) }
        .to raise_error(StandardError)

      auth = proxy.last_request.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    end

    it "honours no_proxy for the target host" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"
      ENV["no_proxy"] = "shop.example.invalid"

      expect do
        Timeout.timeout(2) do
          TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders"))
        end
      end.to raise_error(StandardError)

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end

  describe Portage::Ucp::Check do
    it "routes its manifest/homepage probe through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      described_class.call("shop.example.invalid")

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end

  describe Portage::Ucp::Support::TokenExchange do
    it "routes a token exchange POST through http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect do
        TestTokenExchange.new.exchange("https://shop.example.invalid/oauth/token", { grant_type: "refresh_token" },
                                       error_class: StandardError)
      end.to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end
end

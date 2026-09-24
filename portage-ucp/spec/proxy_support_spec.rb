# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "portage/ucp/support/http_client"
require "portage/ucp/support/token_exchange"
require "portage/ucp/check"
require "base64"
require "timeout"
require "webmock/rspec" # other spec files in this gem require it too, which disables net connect process-wide

# Phase 0 of docs/plans/proxy-support.md documented a real gap here:
# Support::HttpClient, Check and Support::TokenExchange are three of the nine
# raw `Net::HTTP.start(uri.host, uri.port, ...)` call sites the plan lists,
# and none of them passed an explicit `p_addr`, so Net::HTTP's own `:ENV`
# proxy default decided whether an env proxy was used -- and that default
# reads *only* `http_proxy`/`HTTP_PROXY`, for both http and https targets,
# because `Net::HTTP#proxy_uri` hardcodes its env-lookup scheme to "http"
# regardless of `use_ssl?` (docs/design-log.md #44).
#
# Phase 1 replaced every one of these three call sites' raw Net::HTTP.start
# with Support::Connection.start, which resolves the env proxy itself
# instead of leaving Net::HTTP's `:ENV` default in place -- and, unlike
# Net::HTTP, actually reads HTTPS_PROXY/https_proxy for an https:// target.
# These specs assert the *fixed* behavior directly against a real local
# proxy, closing the gap Phase 0 could only document.
class TestHttpClient
  include Portage::Ucp::Support::HttpClient

  public :json_request

  def api_error_class = StandardError
end

class TestTokenExchange
  include Portage::Ucp::Support::TokenExchange

  public :exchange
end

RSpec.describe "Phase 1 env-proxy support via Support::Connection (portage-ucp)" do
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
    it "closes docs/design-log.md #44's gap: routes an https request through HTTPS_PROXY/https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect do
        TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders"))
      end.to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end

    it "no longer reads http_proxy for an https:// target (Net::HTTP's old, now-replaced default did)" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect do
        Timeout.timeout(2) do
          TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders"))
        end
      end.to raise_error(StandardError) # real DNS failure for the *.invalid host -- it went direct

      expect(proxy.last_request(timeout: 1)).to be_nil
    end

    it "routes a plain http:// request through HTTP_PROXY/http_proxy" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      response = TestHttpClient.new.json_request(Net::HTTP::Get, URI("http://shop.example.invalid/orders"), raw: true)
      expect(response.body).to eq("ok")

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to start_with("GET http://shop.example.invalid/orders")
    end

    it "sends Proxy-Authorization from user:pass in the https_proxy URL" do
      ENV["https_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

      expect { TestHttpClient.new.json_request(Net::HTTP::Get, URI("https://shop.example.invalid/orders")) }
        .to raise_error(StandardError)

      auth = proxy.last_request.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    end

    it "honours no_proxy for the target host" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
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
    it "routes its https manifest/homepage probe through https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      described_class.call("shop.example.invalid")

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end

    it "is not routed through http_proxy alone" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      described_class.call("shop.example.invalid")

      expect(proxy.last_request(timeout: 1)).to be_nil
    end
  end

  describe Portage::Ucp::Support::TokenExchange do
    it "routes a token exchange POST through https_proxy" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

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

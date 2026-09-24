# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md: Portage::Ucp::Shopify::Client#post
# is one of the nine raw `Net::HTTP.start(uri.host, uri.port, use_ssl: true)`
# call sites. It passes no explicit `p_addr`, so Net::HTTP's own `:ENV`
# default decides whether an env proxy is used -- this spec runs a real
# local CONNECT-capable proxy (spec/support/local_proxy.rb) and confirms the
# admin-API POST actually reaches it, so a future Support::Connection
# refactor (Phase 1) can't silently regress it.
RSpec.describe "Phase 0 env-proxy support (portage-ucp-shopify)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    WebMock.allow_net_connect! # target hosts here are RFC 2606 .invalid, never actually reachable
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:proxy) { LocalProxy.new }
  let(:client) { Portage::Ucp::Shopify::Client.new(shop_domain: "shop.example.invalid", admin_access_token: "tok") }

  after { proxy.stop }

  it "routes the admin GraphQL POST through http_proxy" do
    ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect do
      client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
    end.to raise_error(StandardError)

    rec = proxy.last_request
    expect(rec).not_to be_nil
    expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
  end

  it "is not reached at all when only https_proxy is set (the confirmed Net::HTTP gap)" do
    ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect do
      Timeout.timeout(3) do
        client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
      end
    end.to raise_error(StandardError)

    expect(proxy.last_request(timeout: 1)).to be_nil
  end

  it "sends Proxy-Authorization from user:pass in the proxy URL" do
    ENV["http_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

    expect do
      client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
    end.to raise_error(StandardError)

    auth = proxy.last_request.header("proxy-authorization")
    expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
  end
end

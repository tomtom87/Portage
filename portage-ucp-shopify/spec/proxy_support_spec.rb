# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md documented a real gap:
# Portage::Ucp::Shopify::Client#post was one of the nine raw
# `Net::HTTP.start(uri.host, uri.port, use_ssl: true)` call sites, with no
# explicit `p_addr`, so Net::HTTP's own `:ENV` proxy default decided whether
# an env proxy was used -- and that default reads *only* `http_proxy`/
# `HTTP_PROXY`, even for this gem's always-https admin API calls, because
# `Net::HTTP#proxy_uri` hardcodes its env-lookup scheme to "http" regardless
# of `use_ssl?` (docs/design-log.md #44).
#
# Phase 1 replaced that raw Net::HTTP.start with
# Portage::Ucp::Support::Connection.start(route: :platform), which resolves
# the env proxy itself instead of leaving Net::HTTP's `:ENV` default in
# place -- and, unlike Net::HTTP, actually reads HTTPS_PROXY/https_proxy.
# This spec asserts the *fixed* behavior directly against a real local
# proxy, closing the gap Phase 0 could only document.
RSpec.describe "Phase 1 env-proxy support via Support::Connection (portage-ucp-shopify)" do
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

  it "closes docs/design-log.md #44's gap: routes the admin GraphQL POST through HTTPS_PROXY/https_proxy" do
    ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect do
      client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
    end.to raise_error(StandardError)

    rec = proxy.last_request
    expect(rec).not_to be_nil
    expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
  end

  it "no longer reads http_proxy alone for this always-https admin API" do
    ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect do
      Timeout.timeout(3) do
        client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
      end
    end.to raise_error(StandardError)

    expect(proxy.last_request(timeout: 1)).to be_nil
  end

  it "sends Proxy-Authorization from user:pass in the https_proxy URL" do
    ENV["https_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

    expect do
      client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
    end.to raise_error(StandardError)

    auth = proxy.last_request.header("proxy-authorization")
    expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
  end

  it "honours no_proxy for the target host" do
    ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
    ENV["no_proxy"] = "shop.example.invalid"

    expect do
      Timeout.timeout(3) do
        client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
      end
    end.to raise_error(StandardError)

    expect(proxy.last_request(timeout: 1)).to be_nil
  end
end

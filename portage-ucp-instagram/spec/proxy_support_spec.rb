# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md documented a real gap:
# AccessTokenFetcher#fetch was one of the nine raw
# `Net::HTTP.start(uri.host, uri.port, use_ssl: true)` call sites, with no
# explicit `p_addr`, so Net::HTTP's own `:ENV` proxy default decided whether
# an env proxy was used -- and that default reads *only* `http_proxy`/
# `HTTP_PROXY`, even for this gem's always-https Graph API call, because
# `Net::HTTP#proxy_uri` hardcodes its env-lookup scheme to "http" regardless
# of `use_ssl?` (docs/design-log.md #44).
#
# Phase 1 replaced that raw Net::HTTP.start with
# Portage::Ucp::Support::Connection.start(route: :platform), which resolves
# the env proxy itself instead of leaving Net::HTTP's `:ENV` default in
# place -- and, unlike Net::HTTP, actually reads HTTPS_PROXY/https_proxy.
# This spec asserts the *fixed* behavior directly against a real local
# proxy, closing the gap Phase 0 could only document.
RSpec.describe "Phase 1 env-proxy support via Support::Connection (portage-ucp-instagram)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    # graph.facebook.com is a real, resolvable host (this fetcher has no
    # configurable endpoint). Every example below sets https_proxy first,
    # so the connection is intercepted by the local proxy before any real
    # socket to Meta opens -- the real network is never actually touched.
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:proxy) { LocalProxy.new }
  let(:fetcher) do
    described_class.new(client_id: "id", client_secret: "secret", short_lived_token: "short")
  end
  let(:described_class) { Portage::Ucp::Instagram::AccessTokenFetcher }

  after { proxy.stop }

  it "closes docs/design-log.md #44's gap: routes the token-exchange GET through HTTPS_PROXY/https_proxy" do
    ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect { fetcher.fetch }.to raise_error(StandardError)

    rec = proxy.last_request
    expect(rec).not_to be_nil
    expect(rec.request_line).to eq("CONNECT graph.facebook.com:443 HTTP/1.1")
  end

  it "sends Proxy-Authorization from user:pass in the https_proxy URL" do
    ENV["https_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

    expect { fetcher.fetch }.to raise_error(StandardError)

    auth = proxy.last_request.header("proxy-authorization")
    expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
  end

  it "honours no_proxy for the target host" do
    ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"
    ENV["no_proxy"] = "graph.facebook.com"

    expect { Timeout.timeout(3) { fetcher.fetch } }.to raise_error(StandardError)

    expect(proxy.last_request(timeout: 1)).to be_nil
  end
end

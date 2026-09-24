# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"

# Phase 0 of docs/plans/proxy-support.md: AccessTokenFetcher#fetch is one of
# the nine raw `Net::HTTP.start(uri.host, uri.port, use_ssl: true)` call
# sites. It passes no explicit `p_addr`, so Net::HTTP's own `:ENV` default
# decides whether an env proxy is used -- this spec runs a real local
# CONNECT-capable proxy (spec/support/local_proxy.rb) and confirms the
# long-lived-token exchange actually reaches it.
RSpec.describe "Phase 0 env-proxy support (portage-ucp-instagram)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    # graph.facebook.com is a real, resolvable host (this fetcher has no
    # configurable endpoint). Every example below sets an env proxy first,
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

  it "routes the token-exchange GET through http_proxy" do
    ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

    expect { fetcher.fetch }.to raise_error(StandardError)

    rec = proxy.last_request
    expect(rec).not_to be_nil
    expect(rec.request_line).to eq("CONNECT graph.facebook.com:443 HTTP/1.1")
  end

  it "sends Proxy-Authorization from user:pass in the proxy URL" do
    ENV["http_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

    expect { fetcher.fetch }.to raise_error(StandardError)

    auth = proxy.last_request.header("proxy-authorization")
    expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
  end
end

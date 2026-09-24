# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"

# Phase 0 of docs/plans/proxy-support.md. portage-ucp-client is the one gem
# in the plan's nine-call-site list that isn't a raw `Net::HTTP.start` --
# its wire transport (Transports::Http) goes through the `mcp` gem's
# MCP::Client::HTTP, which is Faraday-based (`Faraday.new(url)`, no
# `proxy:` option, so `Faraday.ignore_env_proxy` being false by default is
# what makes it read the env proxy at all).
#
# The headline finding: Faraday and Net::HTTP do *not* behave the same.
# Net::HTTP's `:ENV` proxy mode only ever reads `http_proxy`/`HTTP_PROXY`,
# for both http and https targets (see portage-ucp/spec/proxy_support_spec.rb).
# Faraday instead resolves the proxy per the *target's own scheme*
# (`https_proxy` for an https target, `http_proxy` for an http one), with no
# cross-fallback. So this gem's actual UCP/MCP traffic -- unlike every other
# gem's raw Net::HTTP call sites -- genuinely does honor HTTPS_PROXY.
#
# `Client.fetch_manifest`, by contrast, is a bare `Net::HTTP.get_response`
# call (not Faraday, and not one of the plan's nine listed sites, but the
# same family) -- it inherits Net::HTTP's http_proxy-only behavior, so this
# one gem has two different env-proxy behaviors for two halves of the same
# discovery call.
RSpec.describe "Phase 0 env-proxy support (portage-ucp-client)" do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    WebMock.allow_net_connect! # every target here is RFC 2606 .invalid, or is only ever routed to the local proxy
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:proxy) { LocalProxy.new }

  after { proxy.stop }

  describe "MCP::Client::HTTP (Faraday transport, used for all real UCP tool calls)" do
    it "resolves a Faraday proxy from https_proxy for an https endpoint" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      transport = MCP::Client::HTTP.allocate # skip #initialize's eager `connect` network call
      transport.instance_variable_set(:@url, "https://shop.example.invalid/mcp")
      transport.instance_variable_set(:@headers, {})

      conn = transport.send(:client)
      expect(conn.proxy).not_to be_nil
      expect(conn.proxy.uri.port).to eq(proxy.port)
    end

    it "does NOT fall back to http_proxy for an https endpoint (no cross-scheme fallback)" do
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      transport = MCP::Client::HTTP.allocate
      transport.instance_variable_set(:@url, "https://shop.example.invalid/mcp")
      transport.instance_variable_set(:@headers, {})

      expect(transport.send(:client).proxy).to be_nil
    end

    it "actually reaches the local proxy on a real POST, with credentials" do
      ENV["https_proxy"] = "http://bob:s3cr3t@#{proxy.host}:#{proxy.port}"

      transport = MCP::Client::HTTP.allocate
      transport.instance_variable_set(:@url, "https://shop.example.invalid/mcp")
      transport.instance_variable_set(:@headers, {})

      expect { transport.send(:client).post("", { jsonrpc: "2.0" }) }.to raise_error(StandardError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
      auth = rec.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    end
  end

  describe "Transports::Http's proxy: option (Phase 1's 'lighter touch' for this gem)" do
    # docs/plans/proxy-support.md Phase 1: Faraday already reads the env
    # proxy vars itself and accepts a `proxy:` connection option, so this
    # gem's seam is just wiring that option through -- not reimplementing
    # Faraday's own proxy handling (see Transports::Http#initialize).
    it "wires an explicit proxy: option into the Faraday connection regardless of env vars" do
      expect do
        Portage::Ucp::Client::Transports::Http.new(url: "https://shop.example.invalid/mcp",
                                                   proxy: "http://#{proxy.host}:#{proxy.port}")
      end.to raise_error(StandardError) # the *.invalid target can't be reached past the (stub) proxy

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end

    it "reaches the local proxy even when no env proxy variable is set at all" do
      expect do
        Portage::Ucp::Client::Transports::Http.new(url: "https://shop.example.invalid/mcp",
                                                   proxy: "http://#{proxy.host}:#{proxy.port}")
      end.to raise_error(StandardError)

      expect(proxy.last_request).not_to be_nil
    end
  end

  describe "Client.fetch_manifest (plain Net::HTTP.get_response, not Faraday)" do
    it "routes through http_proxy, not https_proxy (inherits the Net::HTTP gap)" do
      ENV["https_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect { Portage::Ucp::Client.discover("https://shop.example.invalid") }
        .to raise_error(Portage::Ucp::Client::DiscoveryError)

      expect(proxy.last_request(timeout: 1)).to be_nil

      ENV.delete("https_proxy")
      ENV["http_proxy"] = "http://#{proxy.host}:#{proxy.port}"

      expect { Portage::Ucp::Client.discover("https://shop.example.invalid") }
        .to raise_error(Portage::Ucp::Client::DiscoveryError)

      rec = proxy.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    end
  end
end

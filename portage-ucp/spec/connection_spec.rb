# frozen_string_literal: true

require "spec_helper"
require "support/local_proxy"
require "base64"
require "timeout"
require "webmock/rspec" # other spec files in this gem require it too, which disables net connect process-wide

# Phase 1 of docs/plans/proxy-support.md: Support::Connection is the one
# shared seam that replaces every raw Net::HTTP.start call site Phase 0
# only observed. These specs exercise the seam itself directly (not through
# HttpClient/Check/TokenExchange -- see proxy_support_spec.rb for those)
# against real local sockets: LocalProxy instances standing in for forward
# proxies/gateways, exactly like Phase 0's own specs, extended here with
# real CONNECT relaying (LocalProxy#relay) so a chain of them can prove a
# hand-rolled multi-hop tunnel actually reaches the far end.
ProxyConfig = Portage::Ucp::Support::ProxyConfig unless defined?(ProxyConfig)
Profile = Portage::Ucp::Support::ProxyConfig::Profile unless defined?(Profile)

RSpec.describe Portage::Ucp::Support::Connection do
  around do |example|
    previous = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { |k| [k, ENV.fetch(k, nil)] }
    previous.each_key { |k| ENV.delete(k) }
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Mirrors Check#get/Buy#fetch_homepage's own redirect-following shape: the
  # caller re-invokes Support::Connection.start per hop, using the *same*
  # route/proxy every time -- Support::Connection has no redirect-following
  # of its own (see connection.rb's doc comment).
  def follow(uri, route:, proxy:, limit: 5)
    return nil if limit.zero?

    response = described_class.start(uri, route: route, proxy: proxy) { |http| http.get(uri.request_uri, {}) }
    if response.is_a?(Net::HTTPRedirection)
      follow(URI.join(uri, response["location"]), route: route, proxy: proxy,
                                                  limit: limit - 1)
    else
      response
    end
  end

  describe "direct mode" do
    it "connects straight to the target when the route resolves to :direct" do
      target = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "probe" => :direct })

      response = described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe,
                                                                                      proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(response.body).to eq("ok")
    ensure
      target&.stop
    end

    it "falls back to direct for a route with no configured profile and no default" do
      target = LocalProxy.new
      proxy = ProxyConfig.new # no routes at all

      response = described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :unlisted,
                                                                                      proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(response.body).to eq("ok")
    ensure
      target&.stop
    end

    it "falls an unlisted route back to the configured default profile" do
      hop = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "default" => { mode: :forward, url: "http://#{hop.host}:#{hop.port}" } })
      # "search" isn't listed as its own route, only "default" is.

      expect do
        described_class.start(URI("https://shop.example.invalid/"), route: :search, proxy: proxy) { |http| http.get("/", {}) }
      end.to raise_error(StandardError)

      expect(hop.last_request.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    ensure
      hop&.stop
    end
  end

  describe "forward mode (single hop, no proxy_headers)" do
    it "builds a native Net::HTTP proxy connection" do
      hop = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "search" => { mode: :forward, url: "http://#{hop.host}:#{hop.port}" } })

      expect do
        described_class.start(URI("https://shop.example.invalid/"), route: :search, proxy: proxy) { |http| http.get("/", {}) }
      end.to raise_error(StandardError) # the *.invalid target can't be reached past the (stub) proxy

      expect(hop.last_request.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    ensure
      hop&.stop
    end

    it "sends Proxy-Authorization from the profile URL's userinfo" do
      hop = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "search" => { mode: :forward,
                                                      url: "http://bob:s3cr3t@#{hop.host}:#{hop.port}" } })

      expect do
        described_class.start(URI("https://shop.example.invalid/"), route: :search, proxy: proxy) { |http| http.get("/", {}) }
      end.to raise_error(StandardError)

      auth = hop.last_request.header("proxy-authorization")
      expect(Base64.decode64(auth.sub(/\ABasic /, ""))).to eq("bob:s3cr3t")
    ensure
      hop&.stop
    end
  end

  describe "forward mode with proxy_headers (hand-rolled single-hop tunnel, open decision 2)" do
    it "reaches a real target through a single relaying hop, carrying the configured proxy_headers on CONNECT" do
      target = LocalProxy.new
      hop = LocalProxy.new(relay: true)
      proxy = ProxyConfig.new(
        routes: { "platform" => { mode: :forward, url: "http://#{hop.host}:#{hop.port}",
                                  proxy_headers: { "X-Egress-Tenant" => "portage" } } }
      )

      response = described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :platform,
                                                                                      proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(response.body).to eq("ok")
      rec = hop.last_request
      expect(rec.request_line).to eq("CONNECT #{target.host}:#{target.port} HTTP/1.1")
      expect(rec.header("x-egress-tenant")).to eq("portage")
    ensure
      target&.stop
      hop&.stop
    end
  end

  describe "forward -> forward chains (hand-rolled nested CONNECT tunnel)" do
    it "reaches the real target through a 2-hop chain" do
      target = LocalProxy.new
      hop2 = LocalProxy.new(relay: true)
      hop1 = LocalProxy.new(relay: true)
      chain = [Profile.new(mode: :forward, url: "http://#{hop1.host}:#{hop1.port}"),
               Profile.new(mode: :forward, url: "http://#{hop2.host}:#{hop2.port}")]
      proxy = ProxyConfig.new(routes: { "platform" => chain })

      response = described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :platform,
                                                                                      proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(response.body).to eq("ok")
      expect(hop1.last_request.request_line).to eq("CONNECT #{hop2.host}:#{hop2.port} HTTP/1.1")
      expect(hop2.last_request.request_line).to eq("CONNECT #{target.host}:#{target.port} HTTP/1.1")
    ensure
      [target, hop1, hop2].each { |p| p&.stop }
    end

    it "reaches the real target through a 3-hop chain" do
      target = LocalProxy.new
      hop3 = LocalProxy.new(relay: true)
      hop2 = LocalProxy.new(relay: true)
      hop1 = LocalProxy.new(relay: true)
      chain = [Profile.new(mode: :forward, url: "http://#{hop1.host}:#{hop1.port}"),
               Profile.new(mode: :forward, url: "http://#{hop2.host}:#{hop2.port}"),
               Profile.new(mode: :forward, url: "http://#{hop3.host}:#{hop3.port}")]
      proxy = ProxyConfig.new(routes: { "platform" => chain })

      response = described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :platform,
                                                                                      proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(response.body).to eq("ok")
      expect(hop1.last_request.request_line).to eq("CONNECT #{hop2.host}:#{hop2.port} HTTP/1.1")
      expect(hop2.last_request.request_line).to eq("CONNECT #{hop3.host}:#{hop3.port} HTTP/1.1")
      expect(hop3.last_request.request_line).to eq("CONNECT #{target.host}:#{target.port} HTTP/1.1")
    ensure
      [target, hop1, hop2, hop3].each { |p| p&.stop }
    end

    it "names hop 2 (not hop 1) when hop 2 rejects the CONNECT with 407" do
      target = LocalProxy.new
      hop2 = LocalProxy.new(relay: true, require_auth: "bob:s3cr3t")
      hop1 = LocalProxy.new(relay: true)
      # hop2 has no credentials configured, so it answers 407.
      chain = [Profile.new(mode: :forward, url: "http://#{hop1.host}:#{hop1.port}"),
               Profile.new(mode: :forward, url: "http://#{hop2.host}:#{hop2.port}")]
      proxy = ProxyConfig.new(routes: { "platform" => chain })

      error = nil
      begin
        described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :platform, proxy: proxy) do |http|
          http.get("/x", {})
        end
      rescue Portage::Ucp::ProxyError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.hop_index).to eq(2)
      expect(error.status).to eq(407)
      expect(error.message).to include("hop 2")
      expect(error.message).to include("407")
    ensure
      [target, hop1, hop2].each { |p| p&.stop }
    end

    it "requires every hop of a hand-rolled chain to be :forward" do
      chain = [Profile.new(mode: :forward, url: "http://127.0.0.1:1"),
               Profile.new(mode: :gateway, url: "http://127.0.0.1:2")]
      proxy = ProxyConfig.new(routes: { "platform" => chain })

      expect do
        described_class.start(URI("http://example.invalid/"), route: :platform, proxy: proxy) { |http| http.get("/", {}) }
      end.to raise_error(ProxyConfig::ConfigError, /forward/)
    end
  end

  describe "gateway mode" do
    it "carries the real target in a configured header, with TLS terminating at the gateway" do
      gateway = LocalProxy.new
      profile = { mode: :gateway, url: "http://#{gateway.host}:#{gateway.port}/fetch", target_header: "X-Target-URL" }
      proxy = ProxyConfig.new(routes: { "platform" => profile })
      target_uri = URI("https://shop.example.invalid/admin/api/graphql.json")

      response = described_class.start(target_uri, route: :platform, proxy: proxy) do |http|
        http.get(target_uri.request_uri, {})
      end

      expect(response.body).to eq("ok")
      rec = gateway.last_request
      expect(rec.request_line).to eq("GET /fetch HTTP/1.1")
      expect(rec.header("x-target-url")).to eq(target_uri.to_s)
    ensure
      gateway&.stop
    end

    it "carries the real target in a configured query parameter" do
      gateway = LocalProxy.new
      profile = { mode: :gateway, url: "http://#{gateway.host}:#{gateway.port}/fetch", target_param: "target" }
      proxy = ProxyConfig.new(routes: { "platform" => profile })
      target_uri = URI("https://shop.example.invalid/x")

      described_class.start(target_uri, route: :platform, proxy: proxy) { |http| http.get(target_uri.request_uri, {}) }

      rec = gateway.last_request
      expect(rec.request_line).to eq("GET /fetch?target=#{URI.encode_www_form_component(target_uri.to_s)} HTTP/1.1")
    ensure
      gateway&.stop
    end

    it "falls back to a {base}/{host}{path} prefix when neither target_header nor target_param is set" do
      gateway = LocalProxy.new
      profile = { mode: :gateway, url: "http://#{gateway.host}:#{gateway.port}/gw" }
      proxy = ProxyConfig.new(routes: { "platform" => profile })
      target_uri = URI("https://shop.example.invalid/x/y")

      described_class.start(target_uri, route: :platform, proxy: proxy) { |http| http.get(target_uri.request_uri, {}) }

      expect(gateway.last_request.request_line).to eq("GET /gw/shop.example.invalid/x/y HTTP/1.1")
    ensure
      gateway&.stop
    end

    it "never follows a redirect off the gateway -- every hop of the caller's own redirect loop stays on it" do
      redirect = "HTTP/1.1 302 Found\r\nLocation: http://evil.example.invalid/\r\nContent-Length: 0\r\n\r\n"
      success = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
      gateway = LocalProxy.new(responses: [redirect, success])
      profile = { mode: :gateway, url: "http://#{gateway.host}:#{gateway.port}/fetch", target_header: "X-Target-URL" }
      proxy = ProxyConfig.new(routes: { "probe" => profile })

      response = follow(URI("https://shop.example.invalid/"), route: :probe, proxy: proxy)

      expect(response.code).to eq("200")
      first = gateway.last_request
      second = gateway.last_request
      expect(first.header("x-target-url")).to eq("https://shop.example.invalid/")
      # The redirect Location pointed off-gateway; the *second* request still
      # landed on this same local gateway process, never dialed
      # evil.example.invalid directly -- that's the guarantee.
      expect(second).not_to be_nil
      expect(second.header("x-target-url")).to eq("http://evil.example.invalid/")
    ensure
      gateway&.stop
    end
  end

  describe "no_proxy matching" do
    let(:hop) { LocalProxy.new }

    after { hop.stop }

    def proxy_for(no_proxy)
      ProxyConfig.new(routes: { "search" => { mode: :forward, url: "http://#{hop.host}:#{hop.port}" } },
                      no_proxy: no_proxy)
    end

    # A bypassed no_proxy match goes *direct* to the (deliberately
    # unresolvable, RFC 2606) `.invalid` target, so it fails downstream —
    # same shape as Phase 0's own "honours no_proxy" spec. What matters is
    # that the proxy never sees the request at all.
    def expect_bypassed(uri, no_proxy)
      expect do
        Timeout.timeout(2) do
          described_class.start(uri, route: :search, proxy: proxy_for(no_proxy)) do |http|
            http.get("/", {})
          end
        end
      end.to raise_error(StandardError)
      expect(hop.last_request(timeout: 1)).to be_nil
    end

    it "bypasses the proxy on an exact match" do
      expect_bypassed(URI("http://shop.example.invalid/"), ["shop.example.invalid"])
    end

    it "bypasses the proxy on a bare-entry subdomain match (suffix rule)" do
      expect_bypassed(URI("http://api.shop.example.invalid/"), ["shop.example.invalid"])
    end

    it "bypasses the proxy on a leading-dot entry's subdomain match" do
      expect_bypassed(URI("http://api.shop.example.invalid/"), [".shop.example.invalid"])
    end

    it "bypasses the proxy for every host when the list contains a bare *" do
      expect_bypassed(URI("http://anything.invalid/"), ["*"])
    end

    it "does not bypass a host that doesn't match any entry -- the request actually reaches the proxy" do
      proxy = proxy_for(["shop.example.invalid"])
      response = described_class.start(URI("http://other.invalid/"), route: :search, proxy: proxy) do |http|
        http.get("/", {})
      end
      expect(response.body).to eq("ok")
      expect(hop.last_request.request_line).to include("other.invalid")
    end
  end

  describe "protected headers" do
    %w[Authorization User-Agent X-Payment-Token X-Shopify-Admin-Access-Token
       X-Shopify-Storefront-Access-Token].each do |name|
      it "refuses #{name} in proxy_headers at profile-construction time" do
        expect do
          Profile.new(mode: :forward, url: "http://proxy.example:3128", proxy_headers: { name => "x" })
        end.to raise_error(ProxyConfig::ConfigError, /#{Regexp.escape(name)}/i)
      end
    end

    it "matches protected header names case-insensitively" do
      expect do
        Profile.new(mode: :forward, url: "http://proxy.example:3128", proxy_headers: { "authorization" => "x" })
      end.to raise_error(ProxyConfig::ConfigError)
    end
  end

  describe "credential redaction" do
    it "never leaks user:pass into a ProxyError raised for a native forward-mode failure" do
      chain = [Profile.new(mode: :forward, url: "http://bob:s3cr3t@127.0.0.1:1"), # nothing listens on port 1
               Profile.new(mode: :forward, url: "http://127.0.0.1:2")]
      proxy = ProxyConfig.new(routes: { "platform" => chain })

      error = nil
      begin
        described_class.start(URI("http://example.invalid/"), route: :platform, proxy: proxy) { |http| http.get("/", {}) }
      rescue Portage::Ucp::ProxyError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.message).not_to include("bob")
      expect(error.message).not_to include("s3cr3t")
      expect(error.message).to include("***")
    end

    it "never leaks user:pass into a ProxyError raised for a rejected hop CONNECT" do
      target = LocalProxy.new
      hop = LocalProxy.new(relay: true, require_auth: "someone:else")
      # proxy_headers forces the hand-rolled tunnel path (open decision 2) --
      # a *native* single-hop forward connection never raises ProxyError at
      # all (Net::HTTP only enforces CONNECT's status for an https:// target,
      # and returns a 407 response object, uncaught, for a plain http:// one).
      proxy = ProxyConfig.new(routes: { "platform" => { mode: :forward, url: "http://bob:s3cr3t@#{hop.host}:#{hop.port}",
                                                        proxy_headers: { "X-Test" => "1" } } })

      error = nil
      begin
        described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :platform, proxy: proxy) do |http|
          http.get("/x", {})
        end
      rescue Portage::Ucp::ProxyError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.message).not_to include("bob")
      expect(error.message).not_to include("s3cr3t")
    ensure
      target&.stop
      hop&.stop
    end
  end

  describe "env-proxy fallback (closing docs/design-log.md #44's gap directly at the seam)" do
    it "honors HTTPS_PROXY/https_proxy for an https:// target when no configured profile applies" do
      hop = LocalProxy.new
      ENV["https_proxy"] = "http://#{hop.host}:#{hop.port}"

      expect do
        described_class.start(URI("https://shop.example.invalid/"), route: :unlisted) { |http| http.get("/", {}) }
      end.to raise_error(StandardError)

      rec = hop.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to eq("CONNECT shop.example.invalid:443 HTTP/1.1")
    ensure
      hop&.stop
    end

    it "honors HTTP_PROXY/http_proxy for an http:// target" do
      hop = LocalProxy.new
      ENV["http_proxy"] = "http://#{hop.host}:#{hop.port}"

      described_class.start(URI("http://shop.example.invalid/"), route: :unlisted) { |http| http.get("/", {}) }

      rec = hop.last_request
      expect(rec).not_to be_nil
      expect(rec.request_line).to start_with("GET http://shop.example.invalid/")
    ensure
      hop&.stop
    end

    it "honors NO_PROXY/no_proxy against the env fallback too" do
      hop = LocalProxy.new
      ENV["https_proxy"] = "http://#{hop.host}:#{hop.port}"
      ENV["no_proxy"] = "shop.example.invalid"

      expect do
        Timeout.timeout(2) { described_class.start(URI("https://shop.example.invalid/"), route: :unlisted) { |http| http.get("/", {}) } }
      end.to raise_error(StandardError)

      expect(hop.last_request(timeout: 1)).to be_nil
    ensure
      hop&.stop
    end

    it "a configured route profile wins over the env proxy, even one set to :direct explicitly" do
      hop = LocalProxy.new
      ENV["https_proxy"] = "http://#{hop.host}:#{hop.port}"
      proxy = ProxyConfig.new(routes: { "payment" => :direct })

      expect do
        Timeout.timeout(2) { described_class.start(URI("https://shop.example.invalid/"), route: :payment, proxy: proxy) { |http| http.get("/", {}) } }
      end.to raise_error(StandardError)

      expect(hop.last_request(timeout: 1)).to be_nil
    ensure
      hop&.stop
    end
  end

  # Phase 3 of docs/plans/proxy-support.md: Support::PassthroughContext is
  # the fiber-local seam an inbound Rack endpoint (CallEndpoint,
  # WebhookEndpoint, ...) sets around the outbound calls it makes while
  # serving one request. These specs exercise Support::Connection's own
  # PassthroughHttp side of that seam directly, with a real LocalProxy
  # standing in for the outbound target so the actual wire headers can be
  # inspected -- the endpoint-level "only from a trusted peer" gate is
  # covered separately, in the WebMCP/webhook endpoint specs.
  describe "passthrough headers (Phase 3)" do
    PassthroughContext = Portage::Ucp::Support::PassthroughContext unless defined?(PassthroughContext)

    it "reaches the outbound request while a PassthroughContext is active" do
      target = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "probe" => :direct })

      PassthroughContext.with(headers: { "X-Shop-Locale" => "en-GB" }) do
        described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
          http.get("/x", {})
        end
      end

      expect(target.last_request.header("x-shop-locale")).to eq("en-GB")
    ensure
      target&.stop
    end

    it "does not appear on an outbound call made outside of any PassthroughContext" do
      target = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "probe" => :direct })

      described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(target.last_request.header("x-shop-locale")).to be_nil
    ensure
      target&.stop
    end

    it "does not leak into a call made after the PassthroughContext block ends" do
      target = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "probe" => :direct })

      PassthroughContext.with(headers: { "X-Shop-Locale" => "en-GB" }) do
        described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
          http.get("/x", {})
        end
      end
      target.last_request # drain the first (in-context) request

      described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
        http.get("/x", {})
      end

      expect(target.last_request.header("x-shop-locale")).to be_nil
    ensure
      target&.stop
    end

    it "restores the previous (outer) context rather than clearing it outright, for nested calls" do
      target = LocalProxy.new
      proxy = ProxyConfig.new(routes: { "probe" => :direct })

      PassthroughContext.with(headers: { "X-Outer" => "1" }) do
        PassthroughContext.with(headers: { "X-Inner" => "1" }) { nil }

        described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
          http.get("/x", {})
        end
      end

      recorded = target.last_request
      expect(recorded.header("x-outer")).to eq("1")
      expect(recorded.header("x-inner")).to be_nil
    ensure
      target&.stop
    end

    describe "forwarded: append|replace|drop" do
      it "drop (the default) never touches the outbound Forwarded/X-Forwarded-For headers" do
        target = LocalProxy.new
        proxy = ProxyConfig.new(routes: { "probe" => :direct })

        PassthroughContext.with(headers: {}, forwarded: "drop", chain_entry: "203.0.113.7") do
          described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
            http.get("/x", {})
          end
        end

        recorded = target.last_request
        expect(recorded.header("x-forwarded-for")).to be_nil
        expect(recorded.header("forwarded")).to be_nil
      ensure
        target&.stop
      end

      it "replace overwrites whatever chain the caller's own request already carried" do
        target = LocalProxy.new
        proxy = ProxyConfig.new(routes: { "probe" => :direct })

        PassthroughContext.with(headers: {}, forwarded: "replace", chain_entry: "203.0.113.7") do
          described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
            http.get("/x", { "X-Forwarded-For" => "198.51.100.9" })
          end
        end

        recorded = target.last_request
        expect(recorded.header("x-forwarded-for")).to eq("203.0.113.7")
        expect(recorded.header("forwarded")).to eq("for=203.0.113.7")
      ensure
        target&.stop
      end

      it "append adds this hop onto the end of the caller's own chain" do
        target = LocalProxy.new
        proxy = ProxyConfig.new(routes: { "probe" => :direct })

        PassthroughContext.with(headers: {}, forwarded: "append", chain_entry: "203.0.113.7") do
          described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
            http.get("/x", { "X-Forwarded-For" => "198.51.100.9" })
          end
        end

        recorded = target.last_request
        expect(recorded.header("x-forwarded-for")).to eq("198.51.100.9, 203.0.113.7")
      ensure
        target&.stop
      end

      it "append with no pre-existing chain just sets this hop's entry" do
        target = LocalProxy.new
        proxy = ProxyConfig.new(routes: { "probe" => :direct })

        PassthroughContext.with(headers: {}, forwarded: "append", chain_entry: "203.0.113.7") do
          described_class.start(URI("http://#{target.host}:#{target.port}/x"), route: :probe, proxy: proxy) do |http|
            http.get("/x", {})
          end
        end

        expect(target.last_request.header("x-forwarded-for")).to eq("203.0.113.7")
      ensure
        target&.stop
      end
    end
  end
end

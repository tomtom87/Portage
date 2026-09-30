require "uri"
require "portage/ucp"
require_relative "handoff_only"
require_relative "handoff_host"
require_relative "check_next_step"
require_relative "webmcp"
require_relative "browser_profile"

module Portage
  module Cli
    # `portage check <url>` — "can Portage buy from this store, and how?"
    #
    # Wraps Portage::Ucp::Check (native `/.well-known/ucp`, platform
    # detection, live adapter probe) and adds what only the CLI knows, so
    # the answer matches what `portage buy` would actually do: the
    # hand-off-only list (HandoffHost, shared with Buy), whether the adapter
    # gem is installed, and whether the page exposes WebMCP tools.
    #
    # Precedence mirrors Buy#call: hand-off-only host, then native UCP, then
    # WebMCP, then a platform adapter, then nothing. A hand-off-only host
    # short-circuits before any request is made.
    #
    # Read-only and quiet: plain GETs only (through Ucp::Check), never a
    # cart, never a checkout. WebMCP needs a live page, and Portage never
    # launches a browser for this: it only reads tools from a tab the
    # Portage browser profile already has open on the store's host
    # (`portage browser profile open --url ...`). With no such tab, or with
    # portage-ucp-webmcp not installed, `webmcp.status` is "skipped" and says
    # why. A `webmcp_bridge:` can be injected instead (specs, library use).
    class Check
      CART_CAP = "dev.ucp.shopping.cart".freeze
      CHECKOUT_CAP = "dev.ucp.shopping.checkout".freeze

      # Verdicts `portage check` exits 0 for.
      USABLE_VERDICTS = %w[automated webmcp].freeze

      NO_TAB_REASON = "no Portage browser profile tab is open on this store " \
                      "(portage browser profile open --url URL), and check never launches a browser".freeze

      def self.call(url, **) = new(url, **).call

      # @param webmcp_bridge [#list_tools, nil] a bridge over the store's page.
      # @param handoff_only [HandoffOnly]
      # @param checker [#call] url -> Portage::Ucp::Check report (injectable).
      def initialize(url, webmcp_bridge: nil, handoff_only: HandoffOnly.new, checker: Portage::Ucp::Check.method(:call))
        raw = url.to_s.strip
        @uri = URI.parse(raw =~ %r{\Ahttps?://}i ? raw : "https://#{raw}")
        @webmcp_bridge = webmcp_bridge
        @handoff_only = handoff_only
        @checker = checker
      end

      def call
        return handoff_only_report if HandoffHost.restricted?(@uri.host, handoff_only: @handoff_only)

        report = @checker.call(@uri.to_s).merge(handoff_only: false)
        report = report.merge(adapter: adapter_for(report))
        report = report.merge(webmcp: webmcp_for(report))
        verdict = verdict_for(report)
        with_index_hint(report.merge(verdict: verdict, next_step: CheckNextStep.call(verdict, report)))
      end

      private

      # docs/plans/local-catalogue.md Phase 2: a Shopify (or native UCP)
      # store's catalogue can be crawled into the local index. Check only
      # names the command; it never crawls.
      def with_index_hint(report)
        return report unless report[:native_ucp] || report[:platform] == "Shopify"

        port = @uri.port == @uri.default_port ? "" : ":#{@uri.port}"
        report.merge(index_hint: "portage index add #{@uri.scheme}://#{@uri.host}#{port} --crawl")
      end

      def handoff_only_report
        { url: @uri.to_s, native_ucp: nil, platform: nil, recommended_gem: nil, handoff_only: true, adapter: nil,
          webmcp: webmcp_skipped("#{@uri.host} is hand-off only, so it isn't probed"),
          verdict: "handoff",
          next_step: "#{@uri.host} restricts automated purchasing agents. Portage opens the page and you buy." }
      end

      # --- adapter ---

      def adapter_for(report)
        platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == report[:platform] }
        return nil unless platform

        { gem: platform.gem, installed: gem_installed?(platform),
          missing_env: Portage::Ucp::Resolver.missing_env(platform, Portage::Ucp::Resolver.env_for(platform)) }
      end

      # Same test the live probe uses: the adapter's require_path either
      # loads or it doesn't. Loading has no I/O.
      def gem_installed?(platform)
        require platform.require_path
        true
      rescue LoadError
        false
      end

      # --- webmcp ---

      def webmcp_for(report)
        return webmcp_skipped("the store speaks UCP natively") if report[:native_ucp]
        return webmcp_skipped("portage-ucp-webmcp isn't installed") unless Webmcp.available?

        bridge = @webmcp_bridge || existing_tab_bridge
        return webmcp_skipped(NO_TAB_REASON) unless bridge

        detect_webmcp(bridge)
      rescue StandardError => e
        { status: "error", tools: [], reason: "#{e.class}: #{e.message}" }
      end

      def webmcp_skipped(reason) = { status: "skipped", tools: [], reason: reason }

      def detect_webmcp(bridge)
        tools = bridge.list_tools
        names = tools.map { |tool| (tool["name"] || tool[:name]).to_s }
        return { status: "none", tools: [], reason: "the page registers no WebMCP tools" } if names.empty?

        preset = Portage::Ucp::WebMcp::Presets.detect(tools)
        session = Portage::Ucp::WebMcp.connect(bridge: bridge, preset: preset)
        return { status: "available", tools: names, reason: nil } if cart_and_checkout?(session)

        { status: "none", tools: names,
          reason: "the page's WebMCP tools aren't a cart and checkout set Portage recognises" }
      end

      def cart_and_checkout?(session) = session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)

      # Only ever a tab that is already open on the store's host: no new tab
      # is created, no browser is started, nothing is navigated.
      def existing_tab_bridge
        profile = BrowserProfile::Profile.new
        return nil unless profile.status[:running]

        tab = BrowserProfile::Cdp.list(port: profile.port).find { |t| t["type"] == "page" && same_host?(t["url"]) }
        ws_url = tab && tab["webSocketDebuggerUrl"]
        return nil unless ws_url

        BrowserProfile::Bridge.new(socket: BrowserProfile::CdpSocket.connect(ws_url),
                                   allowlist: BrowserProfile::Allowlist.new(hosts: [@uri.host]))
      end

      def same_host?(url)
        URI(url.to_s).host == @uri.host
      rescue URI::InvalidURIError
        false
      end

      # --- verdict ---

      def verdict_for(report)
        return "automated" if report[:native_ucp]
        return "webmcp" if report.dig(:webmcp, :status) == "available"
        return "automated" if report.dig(:live_probe, :status) == "ok"
        return "handoff" if report[:platform]

        "unsupported"
      end
    end
  end
end

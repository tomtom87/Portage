require "uri"
require_relative "allowlist"
require_relative "errors"

module Portage
  module Cli
    module BrowserProfile
      # docs/plans/buy-skill-and-local-browser.md Phase 6: the WebMCP
      # bridge `Cli.run_buy` hands to `Buy.new(webmcp_bridge:)` when
      # `--handoff-target profile` — the Portage browser profile's own
      # page target, reached over CdpSocket, wrapped so every call stays
      # inside the domain allowlist. Everything WebMCP-shaped (#list_tools,
      # #execute_tool, #autofill) is delegated to a real
      # Portage::Ucp::WebMcp::Bridges::ScriptEvaluator built from this
      # bridge's own #evaluate — this class exists to add exactly two
      # things ScriptEvaluator doesn't have: the allowlist check on every
      # call, and #navigate (Portage's own deliberate navigation to a
      # checkout URL, as opposed to a page-driven one).
      #
      # Requires `portage-ucp-webmcp` to already be loaded — only ever
      # built by `Cli.run_buy` after `Portage::Cli::Webmcp.available?`,
      # same guard every other WebMCP call site in this gem already uses
      # (see Buy#webmcp_flow) — so nothing here calls `require` itself.
      #
      # #headless? is always false: this is, by construction, a headed
      # browser the shopper can see and pay in (WebMcp::Autofill's own
      # `headless?(bridge)` check — see docs/plans/
      # webmcp-universal-outbound.md Phase 3 — never returns
      # :needs_headed_browser for it).
      class Bridge
        def initialize(socket:, allowlist:)
          @socket = socket
          @allowlist = allowlist
          @page_enabled = false
        end

        def headless? = false

        def location
          raw_evaluate("Promise.resolve(window.location.href)")
        end

        # Portage's own navigation — to the checkout URL a hand-off is
        # about to show the shopper. Permits that URL's host first (this
        # is exactly "the store's checkout host" the allowlist is meant to
        # grow to include, per the plan), then navigates.
        def navigate(url)
          host = URI.parse(url.to_s).host
          @allowlist.permit!(host)
          ensure_page_enabled!
          @socket.call("Page.navigate", "url" => url.to_s)
          nil
        end

        def list_tools = script_evaluator.list_tools
        def execute_tool(name, input) = script_evaluator.execute_tool(name, input)
        def autofill(fields, selectors: {}) = script_evaluator.autofill(fields, selectors: selectors)

        private

        def script_evaluator
          @script_evaluator ||= Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.new(evaluate: method(:evaluate),
                                                                                   headless: false)
        end

        # Every driven call (a WebMCP tool call, an autofill attempt)
        # checks the page's *current* location against the allowlist
        # before running — including a navigation a previous call already
        # caused (e.g. a preset's handoff_checkout tool navigating to
        # checkout): that navigation's own evaluate call already ran
        # before the page moved, so this is the first following call that
        # can actually see where it ended up. That's the plan's "stops the
        # run" in practice — a driven page that jumps somewhere unexpected
        # is caught on its very next use, not mid-navigation (there's no
        # navigation-event hook in this minimal a CDP client).
        def evaluate(expression)
          enforce_allowlist!
          raw_evaluate(expression)
        end

        def enforce_allowlist!
          host = current_host
          return if @allowlist.allowed?(host)

          raise DomainNotAllowedError,
                "the profile browser navigated to #{host.inspect}, outside the allowed domains " \
                "(#{@allowlist.hosts.join(', ')}) — stopping"
        end

        def current_host
          URI.parse(raw_evaluate("Promise.resolve(window.location.href)").to_s).host
        rescue URI::InvalidURIError
          nil
        end

        def raw_evaluate(expression)
          response = @socket.call("Runtime.evaluate", "expression" => expression, "awaitPromise" => true,
                                                      "returnByValue" => true, "userGesture" => true)
          raise_on_exception!(response)
          response.dig("result", "value")
        end

        def raise_on_exception!(response)
          details = response["exceptionDetails"]
          return unless details

          text = details.dig("exception", "description") || details["text"] || "script evaluation failed"
          raise Portage::Ucp::WebMcp::BridgeError, text
        end

        def ensure_page_enabled!
          return if @page_enabled

          @socket.call("Page.enable", {})
          @page_enabled = true
        end
      end
    end
  end
end

require "json"

module Portage
  module Ucp
    module WebMcp
      module Bridges
        # The one Bridge this gem ships: reaches a page's WebMCP tools by
        # evaluating assets/consumer.js in it through whatever browser driver
        # the caller already runs. No driver gem is a dependency — `evaluate:`
        # is any callable that takes a JavaScript expression evaluating to a
        # Promise and returns the value it resolves to (a String here, the
        # consumer's JSON envelope).
        #
        # A Bridge is anything with `#list_tools` (=> Array<Hash>, string keys)
        # and `#execute_tool(name, input)` (=> the tool's raw result), so a
        # caller with a different channel to the browser — a browser
        # extension, a CDP session, a remote grid — can write their own and
        # hand it to Transport directly. `#location` (=> the tab's current
        # URL) is optional on top of that contract — nothing in this gem's
        # own call path needs it, but `Cli::Buy`'s hand-off-only checkout
        # path (docs/plans/webmcp-universal-outbound.md Phase 1) reads it
        # after calling a tool that only navigates the tab rather than
        # returning data, and checks `respond_to?(:location)` first since a
        # hand-rolled Bridge may not implement it. `#headless?` and
        # `#autofill` (Phase 3) are optional the same way, for the same
        # reason: `Cli::Buy`'s autofill path checks `respond_to?` before
        # using either.
        class ScriptEvaluator
          # How much of a driver's own error text a BridgeError quotes — the
          # same cap portage-ucp-decision puts on a Jev reply. Enough to name
          # the problem, not a Selenium DOM dump or a stack trace flooding
          # an agent's context.
          DETAIL_LIMIT = 300

          # Ferrum: `Ferrum::Page#evaluate_async` passes its resolve callback
          # as `arguments[0]`.
          #
          # @param headless [Boolean, nil] whether the browser this page runs
          #   in has no visible window — Ferrum knows this about itself
          #   (`browser.options[:headless]`), so a caller building this from
          #   a Ferrum::Browser can pass it straight through. nil (unset)
          #   means "unknown", which Phase 3's autofill treats the same as
          #   headless (see Autofill) — a shopper who can't see the browser
          #   can't pay in it either way, so the safe default when this
          #   isn't declared is to refuse, not to assume headed.
          def self.ferrum(page, timeout: 30, headless: nil)
            new(evaluate: ->(expression) { page.evaluate_async("(#{expression}).then(arguments[0])", timeout) },
                headless: headless)
          end

          # Playwright (playwright-ruby-client): `Page#evaluate` awaits a
          # returned promise itself.
          def self.playwright(page, headless: nil)
            new(evaluate: ->(expression) { page.evaluate("() => #{expression}") }, headless: headless)
          end

          # Selenium WebDriver: `execute_async_script` passes its done
          # callback as the last argument.
          def self.selenium(driver, headless: nil)
            new(evaluate: lambda { |expression|
              driver.execute_async_script("var done = arguments[arguments.length - 1]; (#{expression}).then(done);")
            }, headless: headless)
          end

          # The expression #list_tools/#execute_tool hand to `evaluate:`.
          def self.expression(operation, name = nil, input = nil)
            "(#{Assets.read('consumer.js')})(#{JSON.generate(operation)}, #{JSON.generate(name)}, " \
              "#{JSON.generate(input)})"
          end

          # The expression #autofill hands to `evaluate:` — assets/autofill.js
          # (Phase 3), not consumer.js's tool-call protocol: this drives the
          # checkout page's own DOM directly rather than a WebMCP tool.
          def self.autofill_expression(fields, selectors)
            "(#{Assets.read('autofill.js')})(#{JSON.generate(fields)}, #{JSON.generate(selectors)})"
          end

          def initialize(evaluate:, headless: nil)
            raise ArgumentError, "evaluate: must respond to #call" unless evaluate.respond_to?(:call)

            @evaluate = evaluate
            @headless = headless
          end

          def list_tools
            Array(run("list"))
          end

          def execute_tool(name, input)
            run("execute", name, input)
          end

          # Not part of the merchant-side registrar's protocol (consumer.js
          # has no "location" operation) — reads the tab's URL straight off
          # `window.location.href` through the same `evaluate:` callable
          # every other call uses, so a driver failure surfaces as the same
          # BridgeError.
          def location
            evaluate("Promise.resolve(window.location.href)")
          end

          # @return [Boolean, nil] nil when the caller never said — see
          #   .ferrum's note on why that's treated as headless by Autofill.
          def headless?
            @headless
          end

          # Fills the checkout page's own contact/shipping fields directly —
          # Phase 3's autofill, never a WebMCP tool call. See assets/autofill.js
          # for exactly what it will and won't touch (never a payment field,
          # never a submit control) and Autofill for the Ruby-side gate this
          # sits behind (headless?, a CAPTCHA/challenge check baked into the
          # script itself).
          #
          # @param fields [Hash{String=>String}] autocomplete token => value.
          # @param selectors [Hash{String=>String}] a preset's fallback CSS
          #   selectors, tried only when no element on the page carries a
          #   matching `autocomplete` attribute for that token.
          # @return [Hash] `{"blocked" => String|nil, "filled" => [...],
          #   "unmatched" => [...], "rate" => [...]}`.
          def autofill(fields, selectors: {})
            unwrap(evaluate(self.class.autofill_expression(fields, selectors)))
          end

          private

          def run(operation, name = nil, input = nil)
            unwrap(evaluate(self.class.expression(operation, name, input)))
          end

          def evaluate(expression)
            @evaluate.call(expression)
          rescue StandardError => e
            raise BridgeError, "browser evaluate failed: #{e.class}: #{excerpt(e.message)}"
          end

          def unwrap(raw)
            envelope = raw.is_a?(String) ? JSON.parse(raw) : raw
            raise BridgeError, "bridge returned #{raw.class}, expected a JSON envelope" unless envelope.is_a?(Hash)

            return envelope["value"] if envelope["ok"]

            raise_failure(envelope["code"], envelope["error"].to_s)
          rescue JSON::ParserError => e
            raise BridgeError, "bridge returned invalid JSON: #{excerpt(e.message)}"
          end

          def excerpt(text)
            text = text.to_s
            text.length > DETAIL_LIMIT ? "#{text[0, DETAIL_LIMIT]}… (#{text.length} chars)" : text
          end

          def raise_failure(code, message)
            case code
            when "no_surface" then raise BridgeError, message
            when "not_registered" then raise ToolNotFoundError, message
            else raise Portage::Ucp::Client::ServerError.new(message, payload: nil)
            end
          end
        end
      end
    end
  end
end

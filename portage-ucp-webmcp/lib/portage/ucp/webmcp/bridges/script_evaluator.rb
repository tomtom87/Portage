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
        # hand it to Transport directly.
        class ScriptEvaluator
          # How much of a driver's own error text a BridgeError quotes — the
          # same cap portage-ucp-decision puts on a Jev reply. Enough to name
          # the problem, not a Selenium DOM dump or a stack trace flooding
          # an agent's context.
          DETAIL_LIMIT = 300

          # Ferrum: `Ferrum::Page#evaluate_async` passes its resolve callback
          # as `arguments[0]`.
          def self.ferrum(page, timeout: 30)
            new(evaluate: ->(expression) { page.evaluate_async("(#{expression}).then(arguments[0])", timeout) })
          end

          # Playwright (playwright-ruby-client): `Page#evaluate` awaits a
          # returned promise itself.
          def self.playwright(page)
            new(evaluate: ->(expression) { page.evaluate("() => #{expression}") })
          end

          # Selenium WebDriver: `execute_async_script` passes its done
          # callback as the last argument.
          def self.selenium(driver)
            new(evaluate: lambda { |expression|
              driver.execute_async_script("var done = arguments[arguments.length - 1]; (#{expression}).then(done);")
            })
          end

          # The expression #list_tools/#execute_tool hand to `evaluate:`.
          def self.expression(operation, name = nil, input = nil)
            "(#{Assets.read('consumer.js')})(#{JSON.generate(operation)}, #{JSON.generate(name)}, " \
              "#{JSON.generate(input)})"
          end

          def initialize(evaluate:)
            raise ArgumentError, "evaluate: must respond to #call" unless evaluate.respond_to?(:call)

            @evaluate = evaluate
          end

          def list_tools
            Array(run("list"))
          end

          def execute_tool(name, input)
            run("execute", name, input)
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

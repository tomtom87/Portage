module Portage
  module Ucp
    module WebMcp
      # One tool call's wait for a page that can't take it yet (see
      # Transport#execute): the call is sent again until it lands or one
      # deadline, set when the wait starts, runs out. Two answers mean the
      # call never ran, so sending it again can't run it twice:
      #
      # - ToolNotFoundError: the page dropped the tool mid-re-render.
      # - One of NOT_READY, thrown by the tool or returned as an `isError`
      #   result. Shopify storefronts answer "Standard Actions are not
      #   available. Ensure Shopify Standard Actions are available before
      #   calling cart tools. Recovery: Try again - this is usually a
      #   transient error." for a moment after their own add_to_cart or
      #   cancel_cart (confirmed live 2026-09-24 on thelightyard.co.uk and
      #   burton.com).
      #
      # Every other error is raised at once: retrying it could run a
      # mutation twice.
      class PageWait
        NOT_READY = [/Standard Actions are not available/].freeze
        RETRY = Object.new.freeze
        private_constant :RETRY

        def self.not_ready?(text) = !text.nil? && NOT_READY.any? { |pattern| pattern.match?(text) }

        # @param raw a CallToolResult Hash, or the same as a JSON string (how
        #   Shopify storefronts' tools answer through the page's WebMCP
        #   surface).
        def self.not_ready_result?(raw)
          raw = parse(raw) if raw.is_a?(String)
          return false unless raw.is_a?(Hash) && raw["isError"]

          not_ready?(Portage::Ucp::Client::ToolResult.text(raw["content"], symbol_keys: false).to_s)
        end

        def self.parse(text)
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
        private_class_method :parse

        # @param now [#call] a monotonic clock, in seconds.
        # @param sleep [#call] sleeps the seconds it's given.
        def initialize(wait:, poll:, now:, sleep:)
          @poll = poll
          @now = now
          @sleep = sleep
          @deadline = now.call + wait
        end

        # @param gone [#call] builds the error to raise when the tool is
        #   still missing at the deadline.
        # @yield sends the call once; its value is the call's result.
        def call(gone:, &send_call)
          loop do
            raw = attempt(gone, &send_call)
            return raw unless raw.equal?(RETRY)

            @sleep.call((@deadline - @now.call).clamp(0, @poll))
          end
        end

        private

        def attempt(gone)
          raw = yield
          self.class.not_ready_result?(raw) && !expired? ? RETRY : raw
        rescue ToolNotFoundError
          raise gone.call if expired?

          RETRY
        rescue Portage::Ucp::Client::ServerError => e
          raise unless self.class.not_ready?(e.message) && !expired?

          RETRY
        end

        def expired? = @now.call >= @deadline
      end
    end
  end
end

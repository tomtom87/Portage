require "digest"

module Portage
  module Ucp
    # Accepts a UCP-shaped request (capability + action + arguments), routes it
    # through the CapabilityRegistry to the backing Adapter method, and wraps
    # the result as MCP's dual content/structuredContent output (see §5).
    class Dispatcher
      # The one action that moves money — see docs/plans/agentic-payments.md
      # Phase 0. Gated by name, not capability, since `complete_checkout` is
      # the only `dev.ucp.shopping.checkout` action that dispatches a charge.
      PAYMENT_COMPLETING_ACTION = "complete_checkout".freeze

      # @param shop [String, nil] identifies which store this Dispatcher
      #   instance is completing charges for, threaded straight onto the
      #   transaction log record — Dispatcher/Adapter have no shared notion
      #   of shop identity today, so this is nil unless the caller passes one.
      # @param transaction_log [Support::TransactionLog] reserve/commit
      #   ledger for `complete_checkout` calls (Phase 0). Injectable so specs
      #   don't write to the real `~/.portage/transactions.json`.
      def initialize(adapter:, registry: CapabilityRegistry.default, logger: Portage::Ucp.configuration.logger,
                     shop: nil, transaction_log: Support::TransactionLog.new)
        @adapter = adapter
        @registry = registry
        @logger = logger
        @shop = shop
        @transaction_log = transaction_log
      end

      # @param correlation_id [String, nil] threaded through to the adapter
      #   (via Support::CheckoutState.with_observability, scoped to this call
      #   only) so a checkout_state_transition event (§12) it emits during
      #   this call carries the same id as the tool_called event that
      #   triggered it. Optional, not correlation_id: required, since
      #   Dispatcher.call is also the conformance kit's
      #   (lib/portage/ucp/rspec.rb) and specs' direct entry point, outside
      #   any MCP request (§23).
      def call(capability:, action:, arguments: {}, correlation_id: nil)
        capability_definition = @registry.find(capability)
        raise UnknownCapabilityError, capability if capability_definition.nil?

        raise CapabilityNotAdvertisedError, capability unless capability_definition.advertised_for?(@adapter)

        method_name = capability_definition.actions[action]
        raise UnknownActionError, action if method_name.nil?

        Portage::Ucp::PaymentTokenGuard.validate!(arguments[:payment_token]) if arguments.key?(:payment_token)

        result = if action == PAYMENT_COMPLETING_ACTION
                   call_and_log_transaction(method_name, arguments, correlation_id)
                 else
                   call_adapter(method_name, arguments, correlation_id)
                 end
        wrap(capability, result)
      end

      private

      # Reserve-then-commit around the one action that dispatches a charge:
      # the `pending` record lands *before* `call_adapter` runs, so a crash
      # during the adapter's own gateway round-trip leaves that record
      # behind rather than nothing. `amount`/`currency` are unknown at
      # reserve time (see TransactionLog#reserve) and filled in from the
      # settled Checkout on success; a raised error settles the record
      # `failed` before re-raising, never left dangling `pending`.
      def call_and_log_transaction(method_name, arguments, correlation_id)
        idempotency_key = arguments.fetch(:idempotency_key)

        @transaction_log.reserve(idempotency_key: idempotency_key, shop: @shop,
                                 checkout_id: arguments[:checkout_id],
                                 payment_token_ref: payment_token_ref(arguments[:payment_token]))

        result = call_adapter(method_name, arguments, correlation_id)

        @transaction_log.complete(idempotency_key: idempotency_key, status: "complete",
                                  amount: settled_amount(result), currency: settled_currency(result))
        result
      rescue StandardError
        @transaction_log.complete(idempotency_key: idempotency_key, status: "failed")
        raise
      end

      # Never persists the payment token itself (single-use, still sensitive
      # even though PaymentTokenGuard has already ruled out a raw PAN) — only
      # a one-way reference an operator can correlate against, not replay.
      def payment_token_ref(payment_token)
        return nil if payment_token.nil?

        Digest::SHA256.hexdigest(payment_token)[0, 16]
      end

      def settled_amount(result)
        return nil unless result.respond_to?(:totals)

        # `Total#amount` is a bare integer minor-unit amount (the parent
        # object's `currency` applies), not a Money struct — see
        # value_objects.rb's Total/Item comments.
        total = Array(result.totals).find { |t| t.type == "total" }
        total&.amount
      end

      def settled_currency(result)
        result.respond_to?(:currency) ? result.currency : nil
      end

      def call_adapter(method_name, arguments, correlation_id)
        unless @adapter.is_a?(Portage::Ucp::Support::CheckoutState)
          return @adapter.public_send(method_name, **arguments)
        end

        Portage::Ucp::Support::CheckoutState.with_observability(@adapter, @logger, correlation_id) do
          @adapter.public_send(method_name, **arguments)
        end
      end

      def wrap(capability_name, result)
        unless result.respond_to?(:to_wire_h)
          return { content: [{ type: "text", text: result.inspect }], structuredContent: result }
        end

        payload = Portage::Ucp::WireEnvelope.wrap(capability_name, result.to_wire_h)
        { content: [{ type: "text", text: payload.inspect }], structuredContent: payload }
      end
    end
  end
end

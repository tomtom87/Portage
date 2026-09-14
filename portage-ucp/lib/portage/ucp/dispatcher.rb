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
      # @param policy [Policy] Phase 2 policy config PolicyGuard.check! reads
      #   caps/velocity/allowlist/token-scope from. Injectable for the same
      #   reason as `transaction_log` — defaulting to `Policy.load` would
      #   have every spec read the real `~/.portage/policy.json`.
      # @param confirmer [#confirm!] Phase 3 gate, run after PolicyGuard
      #   passes, before dispatch. Defaults to `Confirmer::Terminal.new`
      #   (blocks on stdin) — confirmation is on by default per the plan;
      #   specs and conformance suites inject `Confirmer::AutoApprove.new`
      #   instead so a run never blocks waiting on a human.
      # @param order_ledger [Support::OrderLedger] settled-order snapshot
      #   store (Phase 1, docs/plans/order-ledger.md). Injectable for the
      #   same reason as `transaction_log` — defaults to the real
      #   `~/.portage/orders.json`.
      def initialize(adapter:, registry: CapabilityRegistry.default, logger: Portage::Ucp.configuration.logger,
                     shop: nil, transaction_log: Support::TransactionLog.new, policy: Policy.load,
                     confirmer: Confirmer::Terminal.new, order_ledger: Support::OrderLedger.new)
        @adapter = adapter
        @registry = registry
        @logger = logger
        @shop = shop
        @transaction_log = transaction_log
        @policy = policy
        @confirmer = confirmer
        @order_ledger = order_ledger
      end

      # @param correlation_id [String, nil] threaded through to the adapter
      #   (via Support::CheckoutState.with_observability, scoped to this call
      #   only) so a checkout_state_transition event (§12) it emits during
      #   this call carries the same id as the tool_called event that
      #   triggered it. Optional, not correlation_id: required, since
      #   Dispatcher.call is also the conformance kit's
      #   (lib/portage/ucp/rspec.rb) and specs' direct entry point, outside
      #   any MCP request (§23).
      # @param agent_profile [String, nil] caller-supplied `ucp-agent.profile`
      #   hint from `_meta` (see Mcp::Server.agent_profile_for). Dispatcher
      #   has no direct Observability.log call of its own to thread this
      #   into — accepted here purely so callers that already pass
      #   correlation_id: have a matching, equally optional slot; existing
      #   callers that omit it are unaffected.
      def call(capability:, action:, arguments: {}, correlation_id: nil, agent_profile: nil)
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
      #
      # PolicyGuard.check! (Phase 2), then the Confirmer (Phase 3), run
      # after reserve, before dispatch — both need `amount`/`currency` to
      # check the spend cap / show the operator a prompt, which means
      # fetching the checkout via `@adapter.get_checkout` up front rather
      # than waiting for the settled result `call_adapter` would otherwise
      # provide after the charge already happened. A block or a deny never
      # reaches `call_adapter` at all; a pass is recorded immediately so it
      # survives a crash during the adapter round-trip, same reasoning as
      # `reserve`.
      def call_and_log_transaction(method_name, arguments, correlation_id)
        idempotency_key = arguments.fetch(:idempotency_key)
        token_ref = payment_token_ref(arguments[:payment_token])

        result = settle(method_name, arguments, correlation_id, idempotency_key, token_ref)

        # Snapshot AFTER `complete` inside `settle` above, never before/
        # interleaved — opposite of `reserve`'s pre-dispatch posture.
        # Deliberately OUTSIDE `settle`'s rescue: the money has already
        # moved by this point, so if this write raises it must surface only
        # after the transaction record is durably `complete` — a lost local
        # history write must never flip a settled charge to `failed` or
        # leave the transaction record ambiguous. Not every completed
        # checkout produces an order (e.g. cart-only flows), so skip
        # silently when absent.
        @order_ledger.record(idempotency_key: idempotency_key, order: result.order) if result.order
        result
      end

      def settle(method_name, arguments, correlation_id, idempotency_key, token_ref)
        @transaction_log.reserve(idempotency_key: idempotency_key, shop: @shop,
                                 checkout_id: arguments[:checkout_id], payment_token_ref: token_ref)

        checkout = @adapter.get_checkout(checkout_id: arguments[:checkout_id])
        gate!(idempotency_key, checkout, token_ref)

        result = call_adapter(method_name, arguments, correlation_id)

        @transaction_log.complete(idempotency_key: idempotency_key, status: "complete",
                                  amount: settled_amount(result), currency: settled_currency(result))
        result
      rescue StandardError
        @transaction_log.complete(idempotency_key: idempotency_key, status: "failed")
        raise
      end

      # PolicyGuard (Phase 2) then Confirmer (Phase 3), in that order — both
      # gate the same dispatch, and each phase records its own outcome on
      # the transaction record as soon as it passes, per `reserve`'s
      # crash-survives-as-evidence reasoning above.
      def gate!(idempotency_key, checkout, token_ref)
        decision = policy_check!(idempotency_key, checkout, token_ref)
        @transaction_log.record_decision(idempotency_key: idempotency_key, policy_decision: decision)

        confirmation = confirmation_check!(idempotency_key, checkout)
        @transaction_log.record_confirmation(idempotency_key: idempotency_key, confirmation_outcome: confirmation)
      end

      def policy_check!(idempotency_key, checkout, token_ref)
        Portage::Ucp::PolicyGuard.check!(amount: settled_amount(checkout), currency: settled_currency(checkout),
                                         merchant: @shop, token_ref: token_ref, policy: @policy,
                                         transaction_log: @transaction_log)
      rescue Portage::Ucp::PolicyViolationError => e
        @transaction_log.complete(idempotency_key: idempotency_key, status: "failed", policy_decision: e.decision)
        raise
      end

      def confirmation_check!(idempotency_key, checkout)
        @confirmer.confirm!(amount: settled_amount(checkout), currency: settled_currency(checkout),
                            merchant: @shop, idempotency_key: idempotency_key)
      rescue Portage::Ucp::ConfirmationDeniedError => e
        @transaction_log.complete(idempotency_key: idempotency_key, status: "failed", confirmation_outcome: e.decision)
        raise
      end

      # Never persists the payment token itself (single-use, still sensitive
      # even though PaymentTokenGuard has already ruled out a raw PAN) — only
      # a one-way reference an operator can correlate against, not replay.
      def payment_token_ref(payment_token)
        Support::TokenRef.for(payment_token)
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

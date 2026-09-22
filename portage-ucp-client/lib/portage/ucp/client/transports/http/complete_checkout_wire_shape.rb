module Portage
  module Ucp
    module Client
      module Transports
        class Http
          # `complete_checkout`'s real-UCP wire shape — split out of Http
          # itself only to keep that class under Metrics/ClassLength; these
          # methods are private instance methods of Http, not a separate
          # collaborator object, so they still read/raise the same
          # Http-scoped constants and errors.
          module CompleteCheckoutWireShape
            # The one payment handler this transport can build a request for.
            # Reverse-DNS handler id, confirmed live 2026-09-22 in the dev
            # store's checkout `payment_handlers` (see docs handoff) — the key
            # the store itself uses, not the `id`/`spec` fields nested under
            # it (those name the handler's own config, e.g. "shopify.card").
            CARD_HANDLER_ID = "dev.shopify.card".freeze

            # `credential.type` per the payment-handler-guide's discriminated
            # union (ucp.dev/specification/payment/guide, e.g.
            # `tokenizer_card_token` for a `com.example.tokenizer` handler) —
            # the reverse-DNS handler id plus a `_token` suffix. NOT confirmed
            # against a live response (complete_checkout has never been
            # called — see handoff doc); a caller that knows better can
            # override via `credential_type:`.
            CARD_CREDENTIAL_TYPE = "dev.shopify.card_token".freeze

            # Substrings a permission refusal is expected to carry, going by
            # the *shape* of Shopify's other permission error ("You are
            # forbidden to make tools/call requests" on `get_order`,
            # confirmed live — see docs/ucp-tool-gating-investigation.md) and
            # the community-thread description of what's gated
            # (checkout-completion permission / channel not enabled). NOT
            # confirmed for `complete_checkout` itself — no live call has
            # been made. A refusal that doesn't match falls through as a
            # plain ServerError/RequestHandlerError instead of being
            # misreported.
            PERMISSION_REFUSAL_PATTERN = /forbidden|not enabled|not granted|checkout.?completion/i

            # `checkout.payment.instruments[]` — schema pulled live from
            # tools/list 2026-09-22 (see handoff doc): top level needs
            # `id`/`checkout`, `checkout.payment.instruments[]` items need
            # `id`/`handler_id`/`type`, and every handler but apple-pay needs
            # `credential: { token:, type: }`. Only the card handler is
            # wired; any other `handler_id:` the caller passes raises,
            # naming it, rather than guessing a shape that's never been
            # tested live.
            def complete_checkout_body(arguments, idempotency_key)
              handler_id = arguments[:handler_id] || CARD_HANDLER_ID
              raise_unsupported_payment_shape(handler_id) unless handler_id == CARD_HANDLER_ID

              instrument = {
                "id" => "instrument-#{idempotency_key}",
                "handler_id" => handler_id,
                "type" => "card",
                "credential" => { "token" => arguments.fetch(:payment_token),
                                  "type" => arguments[:credential_type] || CARD_CREDENTIAL_TYPE }
              }
              { "id" => arguments.fetch(:checkout_id),
                "checkout" => { "payment" => { "instruments" => [instrument] } } }
            end

            def permission_refusal?(message)
              message.to_s.match?(PERMISSION_REFUSAL_PATTERN)
            end

            def permission_error(cause)
              PaymentPermissionError.new(
                "complete_checkout refused for lack of permission (#{cause.class}: #{cause.message}) — needs " \
                "checkout-completion permission on this client's token and the merchant enabling this agent's " \
                "channel on their shop"
              )
            end

            def raise_unsupported_payment_shape(handler_id)
              raise UnsupportedWireShapeError,
                    "complete_checkout doesn't know how to build a payment instrument for handler " \
                    "#{handler_id.inspect} — only #{CARD_HANDLER_ID.inspect} is wired; apple-pay/shop-pay each " \
                    "need their own credential shape this client hasn't verified against a real payment flow"
            end
          end
        end
      end
    end
  end
end

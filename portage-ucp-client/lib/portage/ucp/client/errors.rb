module Portage
  module Ucp
    module Client
      # Base class for every error this gem raises.
      class Error < StandardError; end

      # Raised when a tool call's JSON-RPC response comes back with
      # `isError: true` — e.g. an AuthenticationError/RateLimitExceededError/
      # RawPanRejectedError the server side surfaced. `#message` is the text
      # content the server returned, not a generic string.
      #
      # On a real UCP server that text is frequently the whole error document
      # rather than a sentence — Shopify answers an out-of-stock `create_cart`
      # with its entire `ucp` envelope (every capability, every payment
      # handler) plus a two-word `messages[].content` of "Sold out" (confirmed
      # live 2026-09-22). Raising that as a several-kilobyte `#message` is
      # accurate and useless to anything that has to show it to a person, so
      # `#payload` carries the parsed document when the text is JSON, and the
      # readers below pull out the parts a caller actually wants. They return
      # nil/[] rather than raising for a server whose text isn't JSON — this
      # is an error path, and failing to parse an error is not worth a second
      # error.
      class ServerError < Error
        attr_reader :payload

        def initialize(message = nil, payload: nil)
          super(message)
          @payload = payload
        end

        # The server's own human-readable explanations, most specific first —
        # `messages[]` entries carry `content`, `code` and `severity`.
        def server_messages
          Array(payload && payload["messages"]).filter_map do |m|
            next unless m.is_a?(Hash)

            { code: m["code"], content: m["content"], severity: m["severity"] }.compact
          end
        end

        # One line fit to print: the server's message content joined, falling
        # back to the raw text when there's no structured document to read.
        def summary
          contents = server_messages.filter_map { |m| m[:content] }
          return message if contents.empty?

          contents.join("; ")
        end

        # Where a shopper can finish by hand — present on Shopify's cart and
        # checkout errors, which is exactly when a CLI wants to offer it.
        def continue_url
          payload && payload["continue_url"]
        end
      end

      # Raised by .discover when the manifest can't be fetched at all: the URL
      # 404s, the host refuses the connection, or the body isn't valid JSON.
      # Indistinguishable from "this store doesn't run UCP" — callers that
      # want to fall back silently for that case should rescue this.
      class DiscoveryError < Error; end

      # Raised by .discover when the manifest *was* fetched and parsed as
      # JSON, but this client couldn't make sense of its shape (no `services`
      # entry advertising an `mcp` transport). Unlike DiscoveryError, this
      # means the store *is* running UCP — the failure is on this client's
      # side, not the store's — so callers shouldn't treat it the same as
      # "no native UCP support" the way a 404 does.
      class ManifestShapeError < DiscoveryError; end

      # Raised by Transports::Http when a call is made without
      # `meta: { agent_profile: <url> }` — real UCP servers (confirmed
      # against Shopify's 2026-08-25 rollout) fetch and verify this URL
      # themselves to identify the calling agent, so there's no sane default
      # to fall back to; better to fail here than pass `meta: nil` through
      # to a 422 the server explains as `profile_unreachable`.
      class MissingAgentProfileError < Error; end

      # Raised by Transports::Http for a mutating call this gem can't yet
      # build the real wire shape for — currently only `complete_checkout`,
      # whose `checkout.payment.instruments` shape (Apple Pay/Shop
      # Pay/card-token variants, each with its own required credential
      # fields) can't be safely guessed without a real payment flow to test
      # against. Raised instead of sending a best-effort shape that might
      # silently misbehave with real money on the line.
      class UnsupportedWireShapeError < Error; end

      # Raised by Transports::Http when a `complete_checkout` call is refused
      # because this client's token lacks checkout-completion permission on
      # the store, or the merchant hasn't enabled this agent's channel (see
      # docs/ucp-tool-gating-investigation.md — that's the one thing genuinely
      # gated in native UCP, granted case by case, no scope picker). Distinct
      # from ServerError (a malformed/declined request the server understood
      # and rejected on its own terms) and from UnsupportedWireShapeError (a
      # handler this client can't build a request for at all) — callers that
      # want to fall back to the checkout's own continue_url should rescue
      # this specifically rather than pattern-matching ServerError#message.
      class PaymentPermissionError < Error; end
    end
  end
end

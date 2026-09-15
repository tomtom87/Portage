require "json"

module Portage
  module Ucp
    module Ap2
      # A typed shape for an AP2 payment mandate (design-log §33/Phase B,
      # citing design-log.md:1984-2117's already-confirmed AP2 gap) — the
      # cart/intent authorization a shopper's agent presents alongside (or
      # instead of) a bare `payment_token`. `amount`/`currency` mirror the
      # minor-unit-integer convention `Total#amount` already uses elsewhere
      # in this gem (see value_objects.rb).
      #
      # `kid` identifies which of the issuing agent's keys `signature` was
      # made with — optional (defaults nil) so existing callers that only
      # ever exercised shape validation keep constructing a PaymentMandate
      # without it; it's required the moment a caller actually wants
      # Ap2::MandateSignature/MandateGuard's `trusted_keys:` to verify the
      # signature cryptographically. `signature` itself is still carried
      # opaquely here — this Data class doesn't verify anything, it's just
      # the shape; see MandateGuard and Ap2::MandateSignature for the two
      # tiers of validation (shape-only vs shape+crypto).
      PaymentMandate = Data.define(:amount, :currency, :merchant, :expires_at, :signature, :kid) do
        def initialize(kid: nil, **rest)
          super
        end

        def to_wire_h
          { "amount" => amount, "currency" => currency, "merchant" => merchant,
            "expires_at" => expires_at, "signature" => signature, "kid" => kid }
        end

        # The exact bytes Ap2::MandateSignature verifies `signature`
        # against — every field but `signature` itself, canonicalized the
        # same way Manifest#sign canonicalizes its own payload (JSON.generate
        # over a fixed-order hash, no key sorting beyond that fixed order,
        # since both sides of a mandate are expected to agree on the field
        # order out of band rather than this gem inventing a JCS-style
        # canonicalization scheme it doesn't need elsewhere).
        def signing_payload
          JSON.generate(
            { "amount" => amount, "currency" => currency, "merchant" => merchant,
              "expires_at" => expires_at, "kid" => kid }
          )
        end
      end
    end
  end
end

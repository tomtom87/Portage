module Portage
  module Ucp
    module Ap2
      # A typed shape for an AP2 payment mandate (design-log §33/Phase B,
      # citing design-log.md:1984-2117's already-confirmed AP2 gap) — the
      # cart/intent authorization a shopper's agent presents alongside (or
      # instead of) a bare `payment_token`. `amount`/`currency` mirror the
      # minor-unit-integer convention `Total#amount` already uses elsewhere
      # in this gem (see value_objects.rb); `signature` is carried opaquely
      # — MandateGuard checks the mandate's *shape*, never the signature
      # itself, since verifying it needs a trust anchor this gem doesn't
      # have (see MandateGuard's own comment).
      PaymentMandate = Data.define(:amount, :currency, :merchant, :expires_at, :signature) do
        def to_wire_h
          { "amount" => amount, "currency" => currency, "merchant" => merchant,
            "expires_at" => expires_at, "signature" => signature }
        end
      end
    end
  end
end

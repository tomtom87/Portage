require "time"

module Portage
  module Ucp
    module Ap2
      # Mandate-*shape* validation (design-log §33/Phase B) — required
      # fields present and not expired. This is deliberately NOT
      # cryptographic AP2 verification: `signature` is carried opaquely
      # (see PaymentMandate) and this guard never inspects it. No key
      # infrastructure or trust anchor exists in this repo to verify a
      # signature against — that's a real external dependency and an
      # explicit non-goal here, the same carve-out the existing plan draws
      # around crypto-signing the confirmation payload. A real PSP adapter
      # is expected to verify a mandate's signature against the issuing
      # agent's trust anchor before ever handing it to this gem.
      module MandateGuard
        REQUIRED_FIELDS = %i[amount currency merchant expires_at signature].freeze

        def self.validate!(mandate)
          missing = REQUIRED_FIELDS.reject { |field| mandate.public_send(field) }
          unless missing.empty?
            raise Portage::Ucp::InvalidMandateError,
                  "payment mandate is missing required field(s): #{missing.join(', ')}"
          end

          return unless Time.now >= Time.parse(mandate.expires_at)

          raise Portage::Ucp::InvalidMandateError,
                "payment mandate expired at #{mandate.expires_at}"
        end
      end
    end
  end
end

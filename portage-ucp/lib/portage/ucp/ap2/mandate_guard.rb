require "time"

module Portage
  module Ucp
    module Ap2
      # Mandate validation (design-log §33/Phase B): required fields present,
      # not expired, and — when the caller supplies a trust anchor —
      # cryptographic proof via Ap2::MandateSignature. `trusted_keys` has no
      # default because this gem has no key infrastructure of its own to
      # default it to (§9's convention: keys are always consumer-provided,
      # never generated or assumed here); a caller that omits it gets
      # shape-only validation, same posture this guard always had, not a
      # silent downgrade. A real PSP adapter is expected to pass the issuing
      # agent's trust anchor (its own store, or a resolver against the
      # agent's own manifest) once it has one. A caller that wants that
      # omission to be an error instead — fail closed rather than silently
      # downgrade to shape-only — sets `require_signature: true`.
      module MandateGuard
        REQUIRED_FIELDS = %i[amount currency merchant expires_at signature].freeze

        # @param trusted_keys [Array<Hash>, #call, nil] forwarded to
        #   Ap2::MandateSignature.verify! when present — see module doc.
        # @param require_signature [Boolean] when true, `trusted_keys`
        #   resolving to nil raises InvalidMandateError instead of falling
        #   back to shape-only validation.
        def self.validate!(mandate, trusted_keys: nil, require_signature: false)
          missing = REQUIRED_FIELDS.reject { |field| mandate.public_send(field) }
          unless missing.empty?
            raise Portage::Ucp::InvalidMandateError,
                  "payment mandate is missing required field(s): #{missing.join(', ')}"
          end

          if Time.now >= Time.parse(mandate.expires_at)
            raise Portage::Ucp::InvalidMandateError,
                  "payment mandate expired at #{mandate.expires_at}"
          end

          if trusted_keys
            Ap2::MandateSignature.verify!(mandate, trusted_keys: trusted_keys)
          elsif require_signature
            raise Portage::Ucp::InvalidMandateError,
                  "payment mandate signature verification is required but no trusted_keys are configured"
          end
        end
      end
    end
  end
end

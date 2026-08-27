require "json"
require "logger"

module Portage
  module Ucp
    # Structured log events (§12), emitted through a consumer-injected logger
    # (defaults to Logger.new($stdout)) so the gem instruments nothing to a
    # specific APM — it just exposes the events. Redacts payment_token,
    # oauth_token, and Authorization by default, plus the PII fields that
    # actually appear on Portage::Ucp::Identity (email) and
    # Portage::Ucp::PostalAddress (name/address/contact) — §23 step 4
    # resolving §12's "Money-adjacent PII" phrase, which named no real key:
    # Money/Total carry amounts and currency only, no PII; the PII that
    # flows through the gem is on identity-linking results and fulfillment
    # destinations instead.
    module Observability
      REDACTED_KEYS = %w[
        payment_token oauth_token authorization
        email first_name last_name phone_number
        street_address extended_address address_locality address_region address_country postal_code
      ].freeze
      REDACTED = "[REDACTED]".freeze

      def self.log(logger, event, **fields)
        logger.info(JSON.generate({ event: event }.merge(redact(fields))))
      end

      def self.redact(value)
        case value
        when Hash
          value.to_h { |key, val| [key, REDACTED_KEYS.include?(key.to_s.downcase) ? REDACTED : redact(val)] }
        when Array
          value.map { |val| redact(val) }
        else
          value
        end
      end
    end
  end
end

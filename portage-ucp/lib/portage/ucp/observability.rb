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
        psp_reference
      ].freeze
      REDACTED = "[REDACTED]".freeze

      def self.log(logger, event, **fields)
        redacted = redact(fields)
        logger.info(JSON.generate({ event: event }.merge(redacted)))
        emit_span(event, redacted)
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

      # Opt-in only — no OTel dependency in the gemspec, so this never fires
      # unless a consumer sets Configuration#tracer to something responding
      # to #in_span(name, attributes:), e.g.
      # `OpenTelemetry.tracer_provider.tracer("portage-ucp")`. The JSON-to-
      # Logger path above is unconditional and unaffected either way — this
      # is an additional emitter over the same already-redacted event set,
      # not a replacement for it.
      def self.emit_span(event, fields)
        tracer = Portage::Ucp.configuration.tracer
        return unless tracer

        # The span exists to record that this event happened, not to wrap
        # any work of its own — #log is a fire-and-forget instrumentation
        # call, so there's nothing to put in the block.
        tracer.in_span(event, attributes: flatten_attributes(fields)) {} # rubocop:disable Lint/EmptyBlock
      end
      private_class_method :emit_span

      # OTel span attributes must be a flat String => String/Numeric/Boolean
      # (or homogeneous array thereof) map — nested hashes aren't valid, so
      # this dot-joins nested keys instead of shipping them as-is.
      def self.flatten_attributes(fields, prefix = nil)
        fields.each_with_object({}) do |(key, value), attrs|
          full_key = prefix ? "#{prefix}.#{key}" : key.to_s
          case value
          when Hash
            attrs.merge!(flatten_attributes(value, full_key))
          when Array
            attrs[full_key] = value.map(&:to_s)
          when nil
            next
          else
            attrs[full_key] = value
          end
        end
      end
      private_class_method :flatten_attributes
    end
  end
end

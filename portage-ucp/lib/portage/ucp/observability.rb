require "json"
require "logger"

module Portage
  module Ucp
    # Structured log events (§12), emitted through a consumer-injected logger
    # (defaults to Logger.new($stdout)) so the gem instruments nothing to a
    # specific APM — it just exposes the events. Redacts payment_token,
    # oauth_token, and Authorization by default so a debugging trail never
    # leaks the exact values this gem is most careful never to log.
    module Observability
      REDACTED_KEYS = %w[payment_token oauth_token authorization].freeze
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

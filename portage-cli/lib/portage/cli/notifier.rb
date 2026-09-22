require "net/http"
require_relative "config"

module Portage
  module Cli
    # Phase 2 of docs/plans/checkout-handoff-delivery.md — POSTs a JSON body
    # to a configured webhook when a `Buy` dead-end (escalation, permission
    # denied, no payment token) hands off a checkout_url, so a caller can
    # wire that into Slack/Zapier/their own relay. Same "the actual
    # notification transport is the caller's job" posture as
    # Portage::Ucp::Confirmer::Webhook's own comments — this class only ever
    # speaks HTTP.
    #
    # Default off. Precedence for the webhook URL (open decision #1,
    # resolved, same shape as CheckoutHandoff's auto-open toggle): a
    # per-invocation `webhook_url:` override (portage buy --notify-webhook)
    # beats PORTAGE_NOTIFY_WEBHOOK_URL, which beats ~/.portage/config.json's
    # "notify_webhook_url" (Config).
    class Notifier
      include Portage::Ucp::Support::HttpClient

      ENV_VAR = "PORTAGE_NOTIFY_WEBHOOK_URL".freeze
      CONFIG_KEY = "notify_webhook_url".freeze

      def initialize(webhook_url: nil, config: Config.load)
        @override = webhook_url
        @config = config
      end

      def webhook_url
        return @override unless @override.nil?

        env = ENV.fetch(ENV_VAR, nil)
        return env unless env.nil? || env.empty?

        @config.get(CONFIG_KEY)
      end

      def enabled? = !webhook_url.to_s.empty?

      # Best-effort, matching CheckoutHandoff's posture: a failed POST never
      # raises out of `Buy#call` — the checkout itself is a real, correct
      # outcome independent of whether this delivery succeeded.
      #
      # @return [String, nil] the delivery failure message, or nil when
      #   disabled or on a successful POST.
      def call(payload)
        return nil unless enabled?

        json_request(Net::HTTP::Post, webhook_url, body: payload)
        nil
      rescue StandardError => e
        e.message
      end

      private

      def api_error_class
        NotifyApiError
      end

      # Raised (internally, always rescued by #call) when the webhook POST
      # itself fails (non-2xx) — kept distinct from a plain network error
      # only in that it carries the response body/status, same split
      # Confirmer::WebhookApiError draws against a raw StandardError.
      class NotifyApiError < Portage::Ucp::Error
        include Portage::Ucp::Support::ApiError

        private

        def api_label
          "Notifier"
        end
      end
    end
  end
end

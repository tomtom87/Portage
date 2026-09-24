require "net/http"
require "json"
require "uri"
require "portage/ucp"
require_relative "config"
require_relative "setting"
require_relative "user_agent"

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
    # resolved, same Setting as CheckoutHandoff's auto-open toggle): a
    # per-invocation `webhook_url:` override (portage buy --notify-webhook)
    # beats PORTAGE_NOTIFY_WEBHOOK_URL, which beats ~/.portage/config.json's
    # "notify_webhook_url" (Config).
    class Notifier
      ENV_VAR = "PORTAGE_NOTIFY_WEBHOOK_URL".freeze
      CONFIG_KEY = "notify_webhook_url".freeze
      TIMEOUT = 5
      # Enough of an error body to name the problem, without pasting a whole
      # HTML error page into the report.
      BODY_EXCERPT = 200

      def initialize(webhook_url: nil, config: Config.load)
        @override = webhook_url
        @config = config
      end

      def webhook_url
        Setting.resolve(override: @override, env: ENV_VAR, config: @config, config_key: CONFIG_KEY)
      end

      def enabled? = !webhook_url.to_s.empty?

      # Best-effort, matching CheckoutHandoff's posture: a failed POST never
      # raises out of `Buy#call` — the checkout itself is a real, correct
      # outcome independent of whether this delivery succeeded.
      #
      # Success is any 2xx, whatever the body: Slack's incoming webhooks
      # answer `ok` as plain text, which a JSON parse would have misreported
      # as a failed delivery. Short timeouts, since a hand-off is waiting on
      # this and Net::HTTP's defaults would stall it for up to two minutes.
      #
      # @return [String, nil] the delivery failure message, or nil when
      #   disabled or on a successful POST.
      def call(payload)
        return nil unless enabled?

        response = post(URI(webhook_url), JSON.generate(payload))
        return nil if response.is_a?(Net::HTTPSuccess)

        "webhook answered #{response.code}: #{response.body.to_s[0, BODY_EXCERPT]}"
      rescue StandardError => e
        "webhook POST failed: #{e.message}"
      end

      private

      def post(uri, body)
        Portage::Ucp::Support::Connection.start(uri, route: :notify, open_timeout: TIMEOUT,
                                                     read_timeout: TIMEOUT) do |http|
          http.post(uri.request_uri, body, HTTP_HEADERS.merge("Content-Type" => "application/json"))
        end
      end
    end
  end
end

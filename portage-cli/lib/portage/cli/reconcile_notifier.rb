require_relative "notifier"
require_relative "macos_notifier"
require_relative "reconcile_notify"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 3 — fans a settle event
    # (`checkout_reconciled`, from HandoffReconciler#notify) out to whichever
    # channels `ReconcileNotify` names. The default `HandoffReconciler`
    # notifier for both `portage buy --wait` and `portage orders reconcile`,
    # replacing the plain webhook-only `Notifier` those used through Phase 1.
    #
    # Every channel is best-effort, same posture as `Notifier#call` itself —
    # one channel failing (a bad webhook URL, no `osascript` on this host)
    # never stops another from firing, and this never raises out of
    # `HandoffReconciler#notify`, which already wraps the whole call in its
    # own rescue.
    class ReconcileNotifier
      def initialize(channels: ReconcileNotify.resolve, webhook: Notifier.new, macos: MacosNotifier.new)
        @channels = channels
        @webhook = webhook
        @macos = macos
      end

      def enabled?(channel) = @channels.include?(channel)

      # @return [String, nil] the webhook channel's own failure message, same
      #   shape `Notifier#call` always returned — the other channels have no
      #   return-value contract to preserve, since nothing read theirs before
      #   this class existed.
      def call(payload)
        error = @webhook.call(payload) if enabled?("webhook")
        notify_macos(payload) if enabled?("macos")
        puts terminal_line(payload) if enabled?("terminal")
        error
      end

      private

      def notify_macos(payload)
        @macos.call(title: "Portage checkout #{payload[:result]}", message: macos_message(payload))
      end

      def macos_message(payload)
        parts = [payload[:shop], format_amount(payload[:amount], payload[:currency])].compact
        parts.empty? ? "checkout #{payload[:checkout_id]}" : parts.join(" — ")
      end

      def terminal_line(payload)
        parts = ["[reconcile] #{payload[:checkout_id]}: #{payload[:result]}"]
        parts << "resolution: #{payload[:resolution]}" if payload[:resolution]
        parts << "order: #{payload[:order_id]}" if payload[:order_id]
        amount = format_amount(payload[:amount], payload[:currency])
        parts << amount if amount
        parts.join(" — ")
      end

      def format_amount(amount, currency)
        return nil unless amount

        "#{format('%.2f', amount / 100.0)}#{" #{currency}" if currency}"
      end
    end
  end
end

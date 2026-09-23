require "json"
require_relative "setting"
require_relative "decisions"

module Portage
  module Cli
    # The confidence gate (docs/plans/system-one-decision-layer.md
    # § Responsibilities 3) as `portage buy` uses it: one yes/no question put
    # to a Decision::ModelBackends backend right before an unattended
    # (`--yes`) completion — "is this checkout what the shopper asked for,
    # and safe to complete without a person looking at it?"
    #
    # Default off. Nothing asks a model anything unless a backend is named,
    # via `--decision-backend NAME` or PORTAGE_DECISION_BACKEND (`jev` or
    # `laya`, Decision::ModelBackends::REGISTRY's keys). The threshold comes
    # from `--min-confidence N` or PORTAGE_MIN_CONFIDENCE, else
    # DEFAULT_THRESHOLD.
    #
    # This answers the plan's open question about how the gate relates to
    # `Confirmer`: it runs in front of the completion, after `--yes` and the
    # local PolicyCheck, and never in place of either. A low score holds the
    # purchase and hands the checkout to the shopper. It never
    # auto-approves anything `--yes` wouldn't already have allowed.
    #
    # Fails closed. An unknown backend name, a backend that isn't configured
    # (no JEV_API_KEY, no Laya bridge), or a backend call that fails all hold
    # the purchase, the same as a low score does. So does naming a backend
    # without portage-ucp-decision installed: the backends live in that
    # optional gem. Once a caller has asked for a confidence check, the
    # check never passing is not "no opinion".
    class ConfidenceCheck
      BACKEND_ENV = "PORTAGE_DECISION_BACKEND".freeze
      THRESHOLD_ENV = "PORTAGE_MIN_CONFIDENCE".freeze
      DEFAULT_THRESHOLD = 0.8
      QUESTION = "safe_to_complete".freeze
      # Phrased so "yes" means "proceed": a noul answer's value is the
      # probability of yes, and that is what ConfidenceGate thresholds.
      INSTRUCTIONS = "The state is a checkout an agent built on a shopper's behalf: the shopper's search " \
                     "query, the merchant, the requested quantity, the checkout's line items and totals, and " \
                     "any warnings about where the checkout differs from the request. Answer yes only if the " \
                     "checkout clearly matches what the shopper asked for and is safe to complete without a " \
                     "person reviewing it first.".freeze

      # @param backend [String, nil] a ModelBackends::REGISTRY key; nil
      #   defers to PORTAGE_DECISION_BACKEND.
      # @param threshold [Float, nil] 0.0..1.0; nil defers to
      #   PORTAGE_MIN_CONFIDENCE, then DEFAULT_THRESHOLD.
      # @param resolver [#call, nil] builds a backend from its name —
      #   injectable so specs never reach a real model. nil means
      #   ModelBackends.resolve, looked up only once a backend is needed.
      def initialize(backend: nil, threshold: nil, resolver: nil)
        @backend_name = Setting.resolve(override: backend, env: BACKEND_ENV)&.to_s&.strip
        @threshold = parse_threshold(Setting.resolve(override: threshold, env: THRESHOLD_ENV) || DEFAULT_THRESHOLD)
        @resolver = resolver
      end

      attr_reader :threshold

      def enabled? = !@backend_name.nil?

      # @param state [Hash] JSON-serializable. Never pass it a payment token.
      # @return [Hash, nil] nil when disabled. Otherwise `proceed:`,
      #   `reason:`, `confidence:`, `threshold:`, `backend:` and `error:`.
      #   `reason` is nil when it proceeds, else why it held:
      #   `below_threshold`, `backend_error` (unknown, unconfigured or
      #   failed backend) or `not_installed` (no portage-ucp-decision).
      #   `error` is the detail behind the last two, nil otherwise.
      def call(state)
        return nil unless enabled?
        return held("not_installed", not_installed_message) unless Decisions.available?

        verdict = Portage::Ucp::Decision::ConfidenceGate.via_backend(
          backend: resolve_backend, state: JSON.generate(state), question: QUESTION,
          instructions: INSTRUCTIONS, threshold: @threshold
        )
        { proceed: verdict.proceed, reason: verdict.proceed ? nil : "below_threshold",
          confidence: verdict.confidence, threshold: @threshold, backend: @backend_name, error: nil }
      rescue StandardError => e
        # Any failure, not only Decision::Error: this runs after a real
        # checkout exists, so an escaped exception would drop the report,
        # the hand-off and the history entry along with the purchase.
        held("backend_error", e.message)
      end

      # What `portage doctor` reports: why the named backend would hold every
      # `--yes` purchase, before one is attempted.
      # @return [String, nil] nil when disabled or ready to answer.
      def configuration_problem
        return nil unless enabled?
        return not_installed_message unless Decisions.available?

        resolve_backend.configuration_problem
      rescue Portage::Ucp::Decision::Error => e
        e.message
      end

      private

      def resolve_backend
        (@resolver || Portage::Ucp::Decision::ModelBackends.method(:resolve)).call(@backend_name)
      end

      def held(reason, error)
        { proceed: false, reason: reason, confidence: nil, threshold: @threshold, backend: @backend_name,
          error: error }
      end

      def not_installed_message
        "portage-ucp-decision is not installed — `gem install portage-ucp-decision` to use the " \
          "#{@backend_name} confidence check."
      end

      def parse_threshold(raw)
        value = Float(raw, exception: false)
        return value if value&.between?(0.0, 1.0)

        raise ArgumentError, "confidence threshold must be a number between 0.0 and 1.0, got #{raw.inspect}"
      end
    end
  end
end

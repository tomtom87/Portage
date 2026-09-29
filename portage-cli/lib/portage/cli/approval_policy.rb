require "portage/ucp"
require_relative "human_prompt"

module Portage
  module Cli
    # `portage policy set --require-approval person|any|off`
    # (docs/plans/human-pick-and-approve.md Phase 2, Design § 5): how much
    # approval a real `portage buy --yes` needs before it may charge or hand
    # off.
    #
    # - `off`: `--yes` alone buys (the behaviour before this setting).
    # - `any` (the default): `--yes` needs `--quote` with an approved quote,
    #   approved by the person at a tty or relayed by an agent.
    # - `person`: only a quote the person approved at the tty counts — a
    #   model with a shell can't type on `/dev/tty`.
    #
    # Stored as `require_approval` in ~/.portage/policy.json (Portage::Ucp::
    # Policy), next to the caps and allowlist it sits beside in `portage
    # policy`. Policy#set takes any key and its file format is documented as
    # private, and PolicyGuard reads only the keys it knows, so this needs
    # no change to the portage-ucp gem. Deliberately no env var or
    # config.json override: either would let an agent lower it without the
    # tty confirmation `policy set` asks for. The gate itself is CLI-only
    # (Cli.approval_gate); Buy's library callers aren't governed by it.
    module ApprovalPolicy
      KEY = "require_approval".freeze
      LEVELS = %w[off any person].freeze
      DEFAULT = "any".freeze

      module_function

      # An unrecognised stored value (a hand-edited file) fails closed, to
      # the strictest level.
      # @return [String] one of LEVELS.
      def level(policy = Portage::Ucp::Policy.load)
        stored = policy.to_h[KEY]
        return DEFAULT if stored.nil?

        LEVELS.include?(stored) ? stored : "person"
      end

      def configured?(policy) = policy.to_h.key?(KEY)

      def lowering?(from, to) = LEVELS.index(to) < LEVELS.index(from)

      # @param quote [Hash, nil] a saved quote (Quotes).
      def satisfied?(quote, level)
        case level
        when "off" then true
        when "any" then [HumanPrompt::BY_PERSON, HumanPrompt::BY_AGENT].include?(quote&.dig("approved_by"))
        else quote&.dig("approved_by") == HumanPrompt::BY_PERSON
        end
      end
    end
  end
end

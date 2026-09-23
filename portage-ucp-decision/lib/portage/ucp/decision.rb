# docs/plans/system-one-decision-layer.md — the typed decision layer that
# sits between the agent loop and the Adapter/client layer: offer ranking,
# escalation policy, confidence gating, and policy checks as inspectable
# data, not control flow scattered across skill instructions and the CLI.
require_relative "decision/version"
require_relative "decision/errors"
require_relative "decision/model_backends"
require_relative "decision/offer_ranking"
require_relative "decision/escalation_policy"
require_relative "decision/confidence_gate"
require_relative "decision/policy_check"

require_relative "errors"
require_relative "model_backends/answer"
require_relative "model_backends/jev"
require_relative "model_backends/laya"

module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md's open question — "Confidence
      # gating needs a defined scale and source" — resolved here for two
      # concrete, swappable model backends: Jev (TypeSafe AI's hosted
      # "System One Model", the plan doc's own namesake) and Laya (an
      # open-weights local model). Both speak the same `#ask(state:,
      # questions:) -> Hash{String => Answer}` shape, so ConfidenceGate can
      # threshold either one's `confidence` without knowing which is behind
      # it.
      module ModelBackends
        REGISTRY = { "jev" => Jev, "laya" => Laya }.freeze

        # @param name [String, Symbol] a REGISTRY key.
        # @return a new backend instance.
        def self.resolve(name, **)
          REGISTRY.fetch(name.to_s) do
            raise Portage::Ucp::Decision::UnknownBackendError,
                  "unknown decision model backend #{name.inspect} — known: #{REGISTRY.keys.join(', ')}"
          end.new(**)
        end
      end
    end
  end
end

module Portage
  module Ucp
    module Decision
      module ModelBackends
        # A single typed question sent to a backend — the wire shape both
        # Jev (api.typesafe.ai/v1/systemone) and the Laya subprocess
        # contract share. `criteria` is a Hash for `type: "choice"`, an
        # Array for `type: "score"`, absent for `type: "noul"` (yes/no).
        Question = Data.define(:type, :instructions, :criteria) do
          def initialize(type:, instructions:, criteria: nil) = super

          def to_wire_h = { "type" => type, "instructions" => instructions, "criteria" => criteria }.compact
        end

        # A single typed answer back from a backend, always carrying a
        # calibrated `confidence` — the field ConfidenceGate thresholds on.
        Answer = Data.define(:type, :confidence, :value, :probabilities) do
          def initialize(type:, confidence:, value: nil, probabilities: nil) = super
        end
      end
    end
  end
end

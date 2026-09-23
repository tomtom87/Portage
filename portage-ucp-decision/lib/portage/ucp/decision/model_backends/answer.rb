require "json"

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

        # A single typed answer back from a backend. `value` is the answer
        # itself (a choice's option, a score's level, a noul's probability of
        # yes). `confidence` is how sure the model is of a choice or score —
        # Jev sends none for a noul, so ConfidenceGate gates a noul on
        # `value` instead.
        Answer = Data.define(:type, :confidence, :value) do
          def initialize(type:, confidence:, value: nil) = super
        end

        # The `{"answers": {name => {...}}}` body both backends return, as
        # Answers. Anything that isn't that shape — invalid JSON, no
        # `answers`, an answer that isn't an object — is a BackendError
        # naming `source`, so a caller rescuing Decision::Error sees every
        # bad reply rather than a stray JSON::ParserError or KeyError.
        #
        # @param raw [String] the backend's response body / stdout.
        # @param source [String] who answered, for the error message.
        # @return [Hash{String => Answer}]
        def self.parse_answers(raw, source:)
          JSON.parse(raw).fetch("answers").transform_values do |answer|
            Answer.new(type: answer["type"], confidence: answer["confidence"],
                       value: answer["choice"] || answer["score"] || answer["noul"])
          end
        rescue JSON::ParserError, KeyError, TypeError, NoMethodError => e
          raise Portage::Ucp::Decision::BackendError,
                "#{source} returned an unreadable answer (#{e.class}: #{e.message}): #{raw.to_s[0, 300].inspect}"
        end
      end
    end
  end
end

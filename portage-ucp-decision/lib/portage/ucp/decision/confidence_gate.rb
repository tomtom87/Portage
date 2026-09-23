module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 3.
      #
      # Wholly new — no precedent in this repo. `Confirmer` is binary
      # (confirm or don't); this is the graded threshold a caller sits in
      # front of it. Where the `confidence:` score itself comes from was the
      # doc's open question — `.via_backend` below answers it for a model
      # backend (ModelBackends::Jev/Laya); `.call` stays the pure comparator
      # for a caller with its own heuristic score.
      module ConfidenceGate
        Verdict = Data.define(:proceed, :confidence, :threshold)

        # @param confidence [Float] 0.0..1.0.
        # @param threshold [Float] 0.0..1.0 — the caller's own risk posture,
        #   not something this gate defaults or infers.
        def self.call(confidence:, threshold:)
          Verdict.new(proceed: confidence >= threshold, confidence: confidence, threshold: threshold)
        end

        # Asks a ModelBackends backend a single question and gates on what it
        # answered, not just on how sure it was:
        #
        # - `"noul"` gates on the probability the answer is yes. Jev sends no
        #   separate `confidence` for a noul (docs.typesafe.ai/api — confirmed
        #   live: `{"type":"noul","noul":0.37}`), so phrase the question so
        #   "yes" means "safe to proceed".
        # - `"choice"`/`"score"` carry a `confidence`, but that's how sure the
        #   model is of whichever answer it gave — a confident "escalate" is
        #   still an escalate. These need `proceed_on:`, matched against the
        #   answer with `===` (an option String for a choice, a Range of levels
        #   for a score): proceed only on a match at or above the threshold.
        #
        # @param backend [#ask] a ModelBackends::Jev/Laya instance (or
        #   anything answering the same `#ask(state:, questions:)` shape).
        # @param state [String]
        # @param question [String] the key the answer comes back under.
        # @param instructions [String] what the backend should evaluate.
        # @param threshold [Float]
        # @param type [String] "noul", "choice", or "score" — ModelBackends'
        #   wire vocabulary.
        # @param criteria [Hash, Array, nil]
        # @param proceed_on [#===, nil] required for "choice"/"score".
        # @return [Verdict]
        # rubocop:disable Metrics/ParameterLists -- all keywords; one question's full wire shape plus its gate
        def self.via_backend(backend:, state:, question:, instructions:, threshold:, type: "noul", criteria: nil,
                             proceed_on: nil)
          # rubocop:enable Metrics/ParameterLists
          if type != "noul" && proceed_on.nil?
            raise ArgumentError, "proceed_on: is required for type: #{type.inspect} — a #{type}'s confidence " \
                                 "says how sure the model is, not which answer it gave"
          end

          asked = { question => ModelBackends::Question.new(type: type, instructions: instructions,
                                                            criteria: criteria) }
          answer = backend.ask(state: state, questions: asked).fetch(question)
          verdict = call(confidence: gated_score(answer, type), threshold: threshold)
          return verdict if type == "noul"

          case answer.value
          when proceed_on then verdict
          else verdict.with(proceed: false)
          end
        end

        def self.gated_score(answer, type)
          score = type == "noul" ? answer.value : answer.confidence
          return score if score.is_a?(Numeric)

          raise Portage::Ucp::Decision::BackendError,
                "#{type} answer carried no #{type == 'noul' ? 'noul probability' : 'confidence'}: #{answer.to_h}"
        end
        private_class_method :gated_score
      end
    end
  end
end

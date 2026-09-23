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

        # Asks a ModelBackends backend one yes/no ("noul") question and gates
        # on the probability it answered yes. Phrase the question so "yes"
        # means "safe to proceed". Jev sends no separate `confidence` for a
        # noul (docs.typesafe.ai/api — confirmed live:
        # `{"type":"noul","noul":0.37}`), and none is needed: the
        # yes-probability is the thing to threshold.
        #
        # Only a noul, on purpose. A choice's or score's `confidence` is how
        # sure the model is of whichever answer it gave, so a confident
        # "escalate" would clear the threshold (Jev did exactly that, at
        # 0.99, for a live `requires_escalation` checkout). A caller that
        # wants a choice or score can ask the backend directly with
        # `#ask` and read the answer itself.
        #
        # @param backend [#ask] a ModelBackends::Jev/Laya instance (or
        #   anything answering the same `#ask(state:, questions:)` shape).
        # @param state [String]
        # @param question [String] the key the answer comes back under.
        # @param instructions [String] what the backend should evaluate.
        # @param threshold [Float]
        # @return [Verdict]
        def self.via_backend(backend:, state:, question:, instructions:, threshold:)
          asked = { question => ModelBackends::Question.new(type: "noul", instructions: instructions) }
          answer = backend.ask(state: state, questions: asked).fetch(question) do
            raise Portage::Ucp::Decision::BackendError, "backend returned no answer for #{question.inspect}"
          end
          unless answer.value.is_a?(Numeric)
            raise Portage::Ucp::Decision::BackendError, "noul answer carried no probability: #{answer.to_h}"
          end

          call(confidence: answer.value, threshold: threshold)
        end
      end
    end
  end
end

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

        # Asks a ModelBackends backend a single question and gates on its
        # reported confidence.
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
        # @return [Verdict]
        def self.via_backend(backend:, state:, question:, instructions:, threshold:, type: "noul", criteria: nil)
          asked = { question => ModelBackends::Question.new(type: type, instructions: instructions,
                                                            criteria: criteria) }
          answer = backend.ask(state: state, questions: asked).fetch(question)
          call(confidence: answer.confidence, threshold: threshold)
        end
      end
    end
  end
end

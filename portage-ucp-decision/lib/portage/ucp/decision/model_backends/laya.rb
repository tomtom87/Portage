require "json"
require "open3"

module Portage
  module Ucp
    module Decision
      module ModelBackends
        # Client for Laya (huggingface.co/convaiinnovations/laya) — a local,
        # open-weights (Apache 2.0) decision-classification model, not a
        # hosted API. No key: it ships as ModernBERT/mmBERT weights invoked
        # through Python (HuggingFace `transformers`/the `laya` SDK), and
        # this is a Ruby gem, so this backend shells out to an external
        # command instead of embedding the model. The command must speak
        # this gem's own stdin/stdout JSON contract — `{"state", "questions"}`
        # in, `{"answers"}` out, the same shape ModelBackends::Jev uses —
        # not any interface Laya's Python side defines itself. Wiring up
        # that command (a thin Python script around `laya.load()` or
        # HuggingFace's `pipeline()`) is left to the caller; this class only
        # owns the Ruby-side contract.
        class Laya
          DEFAULT_COMMAND = "laya-infer".freeze
          ENV_COMMAND_KEY = "LAYA_INFER_COMMAND".freeze

          def initialize(command: ENV.fetch(ENV_COMMAND_KEY, DEFAULT_COMMAND))
            @command = command
          end

          def configured? = !which(@command).nil?

          # @param state [String]
          # @param questions [Hash{String => Question}]
          # @return [Hash{String => Answer}]
          def ask(state:, questions:)
            unless configured?
              raise Portage::Ucp::Decision::BackendNotConfiguredError,
                    "#{@command.inspect} isn't on PATH — install a Laya inference bridge and set " \
                    "#{ENV_COMMAND_KEY}, or point it at one"
            end

            stdout, stderr, status = Open3.capture3(@command, stdin_data: request_json(state, questions))
            raise Portage::Ucp::Decision::BackendError, "Laya command failed: #{stderr}" unless status.success?

            parse(JSON.parse(stdout))
          end

          private

          def request_json(state, questions)
            JSON.generate(state: state, questions: questions.transform_values(&:to_wire_h))
          end

          def parse(body)
            body.fetch("answers").transform_values do |answer|
              Answer.new(type: answer["type"], confidence: answer["confidence"],
                         value: answer["choice"] || answer["score"] || answer["noul"],
                         probabilities: answer["probabilities"])
            end
          end

          def which(command)
            ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, command) }
               .find { |path| File.executable?(path) && !File.directory?(path) }
          end
        end
      end
    end
  end
end

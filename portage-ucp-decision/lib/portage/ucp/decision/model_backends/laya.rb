require "json"
require "open3"

module Portage
  module Ucp
    module Decision
      module ModelBackends
        # Client for Laya (huggingface.co/convaiinnovations/laya) — a local,
        # open-weights (Apache 2.0) decision-classification model, not a
        # hosted API. It ships as ModernBERT/mmBERT weights invoked through
        # Python (HuggingFace `transformers`, or the `laya` SDK's
        # `laya.load()`), and this is a Ruby gem, so this backend shells out
        # to a Python "bridge script" instead of embedding the model. The
        # script must speak this gem's own stdin/stdout JSON contract —
        # `{"state", "questions"}` in, `{"answers"}` out, the same shape
        # ModelBackends::Jev uses — not any interface Laya's Python side
        # defines itself. Writing that script is the caller's job (a
        # starting point is at `examples/laya_bridge.py` in this gem); this
        # class only owns the Ruby-side contract and the two failure modes
        # around it not being there yet: no bridge configured at all, and a
        # configured one that's missing or fails at call time.
        class Laya
          DEFAULT_PYTHON = "python3".freeze
          ENV_BRIDGE_SCRIPT_KEY = "LAYA_BRIDGE_SCRIPT".freeze
          ENV_PYTHON_KEY = "LAYA_PYTHON".freeze
          # Escape hatch for a caller whose bridge isn't `python3 <script>` —
          # a container entrypoint, a wrapper shell script, anything already
          # executable on its own. Takes precedence over bridge_script/python
          # since it's a deliberate override, not a default.
          ENV_COMMAND_KEY = "LAYA_INFER_COMMAND".freeze

          def initialize(bridge_script: ENV.fetch(ENV_BRIDGE_SCRIPT_KEY, nil),
                         python: ENV.fetch(ENV_PYTHON_KEY, DEFAULT_PYTHON),
                         command: ENV.fetch(ENV_COMMAND_KEY, nil))
            @bridge_script = bridge_script
            @python = python
            @custom_command = command
          end

          def configured? = configuration_problem.nil?

          # @param state [String]
          # @param questions [Hash{String => Question}]
          # @return [Hash{String => Answer}]
          def ask(state:, questions:)
            problem = configuration_problem
            raise Portage::Ucp::Decision::BackendNotConfiguredError, problem if problem

            stdout, stderr, status = Open3.capture3(*command, stdin_data: request_json(state, questions))
            raise Portage::Ucp::Decision::BackendError, "Laya bridge failed: #{stderr}" unless status.success?

            parse_answers(stdout)
          end

          private

          # nil means "configured" — anything else is the reason it isn't,
          # returned rather than raised so #configured? and #ask share one
          # check without #configured? having to swallow an exception.
          def configuration_problem
            return nil if @custom_command

            unless @bridge_script
              return "no Laya bridge configured — set #{ENV_BRIDGE_SCRIPT_KEY} to a Python script implementing " \
                     "the state/questions -> answers JSON contract (see examples/laya_bridge.py), or " \
                     "#{ENV_COMMAND_KEY} for a fully custom command"
            end

            return "#{ENV_BRIDGE_SCRIPT_KEY}=#{@bridge_script} does not exist" unless File.file?(@bridge_script)

            return "#{ENV_PYTHON_KEY}=#{@python} isn't on PATH" unless which(@python)

            nil
          end

          def command = @custom_command ? Array(@custom_command) : [@python, @bridge_script]

          def request_json(state, questions)
            JSON.generate(state: state, questions: questions.transform_values(&:to_wire_h))
          end

          def parse_answers(stdout)
            parse(JSON.parse(stdout))
          rescue JSON::ParserError => e
            raise Portage::Ucp::Decision::BackendError,
                  "Laya bridge produced invalid JSON (#{e.message}): #{stdout.inspect}"
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

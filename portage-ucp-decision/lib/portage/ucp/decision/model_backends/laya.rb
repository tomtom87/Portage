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
          # Seconds. Generous, since the bridge loads model weights on every
          # call, but bounded: a stuck bridge must hold the purchase, not
          # hang it.
          DEFAULT_TIMEOUT = 60

          def initialize(bridge_script: ENV.fetch(ENV_BRIDGE_SCRIPT_KEY, nil),
                         python: ENV.fetch(ENV_PYTHON_KEY, DEFAULT_PYTHON),
                         command: ENV.fetch(ENV_COMMAND_KEY, nil), timeout: DEFAULT_TIMEOUT)
            @bridge_script = bridge_script
            @python = python
            @custom_command = command
            @timeout = timeout
          end

          def configured? = configuration_problem.nil?

          # @param state [String]
          # @param questions [Hash{String => Question}]
          # @return [Hash{String => Answer}]
          def ask(state:, questions:)
            problem = configuration_problem
            raise Portage::Ucp::Decision::BackendNotConfiguredError, problem if problem

            stdout, stderr, status = run(request_json(state, questions))
            raise Portage::Ucp::Decision::BackendError, "Laya bridge failed: #{stderr}" unless status.success?

            ModelBackends.parse_answers(stdout, source: "Laya bridge")
          end

          # nil means "configured" — anything else is the reason it isn't,
          # returned rather than raised so #configured?, #ask and a setup
          # check (portage doctor) share one check without swallowing an
          # exception.
          def configuration_problem
            return nil if @custom_command

            unless @bridge_script
              return "no Laya bridge configured — set #{ENV_BRIDGE_SCRIPT_KEY} to a Python script implementing " \
                     "the state/questions -> answers JSON contract (see examples/laya_bridge.py), or " \
                     "#{ENV_COMMAND_KEY} for a fully custom command"
            end

            return "#{ENV_BRIDGE_SCRIPT_KEY}=#{@bridge_script} does not exist" unless File.file?(@bridge_script)

            return "#{ENV_PYTHON_KEY}=#{@python} isn't an executable on PATH" unless which(@python)

            nil
          end

          private

          def command = @custom_command ? Array(@custom_command) : [@python, @bridge_script]

          def request_json(state, questions)
            JSON.generate(state: state, questions: questions.transform_values(&:to_wire_h))
          end

          # Open3.capture3 with a deadline: the child is killed, not left
          # running, when it overruns. A command that can't start at all
          # (ENOENT, EACCES) is a BackendError like any other bridge failure.
          def run(input)
            Open3.popen3(*command) do |stdin, stdout, stderr, wait|
              readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
              write_request(stdin, input)
              timed_out = wait.join(@timeout).nil?
              Process.kill("KILL", wait.pid) if timed_out
              # After a kill, a grandchild (a wrapper's python) can still hold
              # the pipes open, so don't wait on the readers indefinitely.
              out, err = readers.map { |reader| reader.join(timed_out ? 1 : nil)&.value.to_s }
              raise Portage::Ucp::Decision::BackendError, "Laya bridge timed out after #{@timeout}s" if timed_out

              [out, err, wait.value]
            end
          rescue SystemCallError, IOError => e
            raise Portage::Ucp::Decision::BackendError, "Laya bridge couldn't run #{command.first}: #{e.message}"
          end

          # A bridge that exits without reading its stdin closes the pipe
          # early. Its exit status and stderr say why, so that's reported
          # rather than the EPIPE.
          def write_request(stdin, input)
            stdin.write(input)
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close
          end

          # A path (LAYA_PYTHON=/opt/venv/bin/python) is checked as-is; a
          # bare name is looked up on PATH.
          def which(command)
            return (executable_file?(command) ? command : nil) if command.include?("/")

            ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, command) }
               .find { |path| executable_file?(path) }
          end

          def executable_file?(path) = File.executable?(path) && !File.directory?(path)
        end
      end
    end
  end
end

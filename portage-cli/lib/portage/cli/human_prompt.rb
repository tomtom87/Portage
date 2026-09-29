module Portage
  module Cli
    # The one way portage-cli asks a person something during a buy —
    # `portage pick` (loop step 3), `portage approve` (step 5), the numbered
    # pick `portage buy --query` shows, and the confirmation that lowers
    # `--require-approval` (docs/plans/human-pick-and-approve.md Phase 2,
    # Design § 3).
    #
    # Two surfaces:
    #
    # - `tty` reads and writes `/dev/tty`, not stdin/stdout, so it still
    #   reaches the person when stdout is piped to an agent. An answer typed
    #   there is recorded `by: "person"`. With no controlling terminal
    #   (opening `/dev/tty` fails, e.g. ENXIO) it raises NoTerminal, which
    #   each command reports as a clean `no_terminal` outcome.
    # - `agent` prompts nobody: the command returns a `needs_*` outcome with
    #   render-ready choices, and the agent relays the person's answer
    #   (`--choose`, `--relayed-yes`), recorded `by: "agent_relayed"`.
    #
    # `via: "auto"` (the default) is `tty` when there's a controlling
    # terminal and the run isn't `--json`, else `agent`.
    #
    # `terminal:` is injectable (anything with #gets/#print/#puts), so specs
    # never open the real `/dev/tty`; the default is HumanPrompt.open_terminal.
    class HumanPrompt
      PATH = "/dev/tty".freeze
      VIAS = %w[auto tty agent].freeze
      BY_PERSON = "person".freeze
      BY_AGENT = "agent_relayed".freeze

      class NoTerminal < StandardError; end

      def self.open_terminal = File.open(PATH, "r+")

      # @param via [String] one of VIAS.
      # @param json [Boolean] whether the run is `--json` (only read by `auto`).
      # @param terminal [#gets, #print, #puts, nil] an already-open terminal.
      def initialize(via: "auto", json: false, terminal: nil)
        raise ArgumentError, "Unknown --via #{via.inspect} (auto, tty or agent)" unless VIAS.include?(via)

        @via = via
        @json = json
        @terminal = terminal
      end

      # @return [String] "tty" or "agent".
      def surface
        @surface ||= case @via
                     when "tty", "agent" then @via
                     else !@json && terminal ? "tty" : "agent"
                     end
      end

      def tty? = surface == "tty"

      # A numbered pick. `v N` calls `view` with that choice and asks again
      # — viewing is never an answer. Blank (or end of input) cancels; any
      # other answer that isn't a listed number asks again.
      # @param choices [Array<Hash>] each with `:label`.
      # @param view [#call, nil] choice -> message to show.
      # @return [Integer, nil] the chosen index, nil when cancelled.
      def choose(question, choices, view: nil)
        choices.each_with_index { |choice, i| say("  #{i + 1}. #{choice[:label]}") }
        hint = view ? ", v N to view" : ""
        loop do
          answer = ask("#{question} (1-#{choices.length}#{hint}, Enter to cancel): ")
          return nil if answer.empty?

          index = chosen_index(answer, choices.length)
          next say("Not one of the choices.") unless index
          return index unless answer.match?(/\Av/i)

          say(view ? view.call(choices[index]) : "Nothing to view.")
        end
      end

      # A yes/no. `v` calls `view` and asks again; only "y"/"yes" is a yes.
      # @return [Boolean]
      def confirm(question, view: nil)
        loop do
          answer = ask("#{question} [y/N#{', v to view' if view}] ").downcase
          return %w[y yes].include?(answer) unless answer == "v" && view

          say(view.call)
        end
      end

      def say(text) = terminal!.puts(text)

      private

      def ask(question)
        terminal!.print(question)
        terminal!.flush if terminal!.respond_to?(:flush)
        terminal!.gets.to_s.strip
      end

      # "3" or "v 3" (1-based), within range.
      def chosen_index(answer, count)
        number = answer[/\A(?:v\s*)?(\d+)\z/i, 1]
        return nil unless number

        number.to_i.between?(1, count) ? number.to_i - 1 : nil
      end

      def terminal!
        terminal || raise(NoTerminal, "No terminal to ask on (#{PATH} can't be opened) — run with --via agent " \
                                      "and relay the person's answer, or run this from a terminal.")
      end

      def terminal
        @terminal ||= self.class.open_terminal
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end

require "io/console"

module Portage
  module Cli
    class SetupWizard
      # The one place every step reads a question and prints a line — so
      # "Enter/blank keeps the current value", "y/N confirm" and "never
      # echo a secret" (docs/plans/buy-skill-and-local-browser.md Phase 4)
      # are each implemented once instead of per step. Defaults to the real
      # $stdin/$stdout, like WebmcpMappingConfirm/BrowserImport::Confirm —
      # a spec swaps in a fake input/output (or stubs the real $stdin the
      # same way cli_spec.rb already does for `browser import`).
      class Prompt
        def initialize(input: $stdin, output: $stdout)
          @input = input
          @output = output
        end

        def say(text) = @output.puts(text)

        # @return [Boolean] `default` when the answer is blank; otherwise
        #   whether the answer starts with "y".
        def confirm(question, default: true)
          @output.print("#{question} [#{default ? 'Y/n' : 'y/N'}] ")
          @output.flush
          answer = @input.gets.to_s.strip.downcase
          return default if answer.empty?

          answer.start_with?("y")
        end

        # @return [String, nil] nil for a blank answer — Enter keeps
        #   whatever's already set, and the step decides what that means.
        def ask(question, hint: nil)
          @output.print("#{question}#{" (#{hint})" if hint}: ")
          @output.flush
          blank_to_nil(@input.gets.to_s.chomp)
        end

        # Same contract as #ask, but the answer is never echoed to the
        # terminal: IO#noecho when `@input` is a real, attached tty (a
        # spec's stubbed-but-otherwise-real $stdin isn't, so this falls
        # back to a plain read there, same as a piped stdin in production).
        def ask_secret(question, hint: nil)
          @output.print("#{question}#{" (#{hint})" if hint}: ")
          @output.flush
          answer = read_secret
          @output.puts
          blank_to_nil(answer.to_s.chomp)
        end

        private

        def blank_to_nil(text)
          text = text.strip
          text.empty? ? nil : text
        end

        def read_secret
          @input.noecho(&:gets).to_s
        rescue Errno::ENOTTY, NoMethodError, IOError
          @input.gets.to_s
        end
      end
    end
  end
end

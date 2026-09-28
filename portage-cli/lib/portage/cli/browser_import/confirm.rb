module Portage
  module Cli
    module BrowserImport
      # The "shows the list and asks before writing" gate (docs/plans/
      # buy-skill-and-local-browser.md Phase 3), shaped like
      # WebmcpMappingConfirm: an explicit `--yes` is the only way to save
      # without a prompt; a prompt needs a real TTY and no `--json`; and
      # anything else — piped, CI, an agent running `--json` — saves
      # nothing and says how to confirm. A dry run never saves, `--yes` or
      # not.
      class Confirm
        # @param interactive [Boolean] false under --json or with no TTY on
        #   stdin (the caller decides).
        def initialize(interactive:, input: $stdin, output: $stdout)
          @interactive = interactive
          @input = input
          @output = output
        end

        # @return [Symbol] :save, :declined, :dry_run, :nothing, or
        #   :needs_confirmation (no TTY/--json and no --yes).
        def call(plan, yes:, dry_run:)
          return :dry_run if dry_run
          return :nothing if Array(plan[:kept]).empty?
          return :save if yes
          return :needs_confirmation unless @interactive

          @output.print "Save these #{plan[:kept].length} store(s) to your local index? [y/N] "
          @output.flush
          @input.gets.to_s.strip.downcase == "y" ? :save : :declined
        end
      end
    end
  end
end

require_relative "setup_wizard/prompt"
require_relative "setup_wizard/steps/shipping"
require_relative "setup_wizard/steps/search_keys"
require_relative "setup_wizard/steps/agent_profile"
require_relative "setup_wizard/steps/browser_import"
require_relative "setup_wizard/steps/index_build"
require_relative "setup_wizard/steps/policy"
require_relative "setup_wizard/steps/handoff"

module Portage
  module Cli
    # `portage setup`'s interactive wizard (docs/plans/
    # buy-skill-and-local-browser.md Phase 4) — Cli.run_doctor/run_setup
    # decide *whether* to run this (a real TTY, no --json, and either the
    # command was `setup` outright or `doctor`/`configure` found nothing
    # configured at all; see Doctor#nothing_configured?); this class is
    # just the seven steps themselves, once that decision is already made.
    #
    # Every step: says what it's for, offers to skip (Enter keeps its own
    # default — "on" for the foundational steps, "off" for the two that are
    # opt-in network/filesystem sweeps: browser import and index build),
    # and re-runs cleanly — Enter on any individual question inside a step
    # always keeps whatever's already set, never clears it. No step raises
    # its own error class: each one leans on the command it delegates to
    # (`portage generate agent-profile`, `portage browser import`, `portage
    # index build`, `portage policy set`) for its own validation and error
    # reporting, so this class has nothing UCP- or network-specific to
    # rescue.
    class SetupWizard
      INTRO = <<~TEXT.freeze
        Portage setup

        Walks through shipping, search, your agent profile, browser import,
        the local store index, spending caps and hand-off. Every step can
        be skipped, and this re-runs cleanly at any time — nothing you
        already have set is cleared just by pressing Enter.
      TEXT

      STEPS = [Steps::Shipping, Steps::SearchKeys, Steps::AgentProfile, Steps::BrowserImport,
               Steps::IndexBuild, Steps::Policy, Steps::Handoff].freeze

      def initialize(input: $stdin, output: $stdout)
        @prompt = Prompt.new(input: input, output: output)
      end

      # @return [Integer] always 0 — nothing about walking through (or
      #   skipping) setup steps is a failure exit code; a step that hits a
      #   real problem (a bad flag reaching `portage policy set`, a browser
      #   import permission error) reports it itself, same as running that
      #   command directly would.
      def call
        @prompt.say(INTRO)
        STEPS.each { |step_class| run_step(step_class) }
        @prompt.say("\nDone — run `portage doctor` any time to see the current state, or `portage setup` " \
                    "again to change anything above.")
        0
      end

      private

      def run_step(step_class)
        step = step_class.new(prompt: @prompt)
        @prompt.say("\n== #{step.title} ==")
        return @prompt.say("Skipped.") unless @prompt.confirm("Configure this now?", default: step.default_yes?)

        step.call
      end
    end
  end
end

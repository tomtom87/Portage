require_relative "../../config"
require_relative "../../checkout_handoff"
require_relative "../../handoff_target"
require_relative "../../handoff_only"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 7 (docs/plans/buy-skill-and-local-browser.md Phase 4 built
        # the auto-open toggle; Phase 5 extends it): auto-open, the
        # hand-off target, an approved named agent, and the hand-off-only
        # host list — all through Config, the same "Enter keeps what's
        # already set" contract every other step uses.
        class Handoff
          def initialize(prompt:) = @prompt = prompt

          def title = "Hand-off"
          def default_yes? = true

          def call
            @prompt.say("When a buy hands off — no payment token, an escalation, or a dead end — Portage " \
                        "opens the checkout URL (or dispatches it to an approved agent). Amazon and any " \
                        "other host on your hand-off-only list are never automated: Portage just opens the " \
                        "page and you buy. #{HandoffOnly::LEGAL_NOTICE}")
            toggle_auto_open
            set_handoff_target
            approve_agent
            edit_handoff_only_hosts
          end

          private

          def toggle_auto_open
            current = CheckoutHandoff.new.auto_open?
            answer = @prompt.confirm("Auto-open the checkout URL in your browser on hand-off?", default: current)
            return @prompt.say("Left unchanged.") if answer == current

            Config.load.set("auto_open_checkout", answer)
            @prompt.say("Saved to ~/.portage/config.json.")
          end

          def set_handoff_target
            current = HandoffTarget.new.label
            answer = @prompt.ask("Hand-off target", hint: "default, print, profile, or agent:<name>; " \
                                                          "currently #{current}; Enter to keep it")
            return @prompt.say("Left unchanged.") if answer.nil?

            HandoffTarget.new(override: answer) # validates before saving
            Config.load.set("handoff_target", answer)
            @prompt.say("Saved to ~/.portage/config.json.")
          rescue ArgumentError => e
            @prompt.say("#{e.message} Not saved.")
          end

          # Approving an `agent:<name>` target once here (or by editing
          # config.json directly) is what #lookup requires before Buy will
          # ever invoke it (see HandoffAgents) — nothing is approved just
          # by naming it as the hand-off target above.
          def approve_agent
            name = @prompt.ask("Approve a named agent for agent:<name> hand-off", hint: "agent name, Enter to skip")
            return unless name

            command = @prompt.ask("Command to run it", hint: "space-separated argv, e.g. openclaw handoff; " \
                                                             "Enter to use a webhook instead")
            return approve_agent_webhook(name) unless command

            save_agent(name, "command" => command.split)
          end

          def approve_agent_webhook(name)
            webhook = @prompt.ask("Webhook URL", hint: "https://..., Enter to skip")
            return @prompt.say("No command or webhook given — #{name.inspect} not saved.") unless webhook

            save_agent(name, "webhook" => webhook)
          end

          def save_agent(name, entry)
            config = Config.load
            agents = config.get("handoff_agents") || {}
            agents[name] = entry.merge("approved" => true)
            config.set("handoff_agents", agents)
            @prompt.say("Approved #{name.inspect} — use --handoff-target agent:#{name}.")
          end

          def edit_handoff_only_hosts
            current = HandoffOnly.new.hosts
            @prompt.say("Current hand-off-only hosts (#{current.length}): #{current.join(', ')}")
            answer = @prompt.ask("Replace the list", hint: "comma-separated hosts, Enter to keep it as-is")
            return @prompt.say("Left unchanged.") if answer.nil?

            hosts = answer.split(",").map(&:strip).reject(&:empty?)
            Config.load.set("handoff_only_hosts", hosts)
            @prompt.say("Saved #{hosts.length} host(s) to ~/.portage/config.json.")
          end
        end
      end
    end
  end
end

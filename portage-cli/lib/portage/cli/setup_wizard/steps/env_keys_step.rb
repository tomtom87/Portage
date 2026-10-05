require_relative "../../dot_env"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Shared body of the wizard steps that only prompt for a few env vars
        # and write the answers to ~/.portage/.env (Shipping, SearchKeys,
        # RetailerKeys). A subclass defines #title, #default_yes?, FIELDS
        # ({ "ENV_VAR" => "label" }), #intro and #unchanged_message, and
        # overrides #secret? for fields that must never echo back.
        class EnvKeysStep
          def initialize(prompt:) = @prompt = prompt

          def call
            @prompt.say(intro)
            assignments = collect
            return @prompt.say(unchanged_message) if assignments.empty?

            path = DotEnv.update!(assignments)
            @prompt.say("Saved #{assignments.keys.join(', ')} to #{path} (chmod 600).")
          end

          private

          def fields = self.class::FIELDS
          def secret?(_var) = false

          def collect
            fields.each_with_object({}) do |(var, label), assignments|
              hint = ENV.fetch(var, nil).to_s.empty? ? "not set" : "already set"
              answer = secret?(var) ? @prompt.ask_secret(label, hint: hint) : @prompt.ask(label, hint: hint)
              assignments[var] = answer if answer
            end
          end
        end
      end
    end
  end
end

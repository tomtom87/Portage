require "open3"

module Portage
  module Cli
    class PaymentMethods
      # macOS Keychain, via the `security` CLI (Open3 — array args, never an
      # interpolated shell string, so an id/token containing shell metachars
      # can't inject). The token is the generic-password's own secret; `id`
      # is the account name, always scoped to SERVICE so it never collides
      # with an unrelated Keychain entry.
      class KeychainBackend
        SERVICE = "portage-cli-payment".freeze

        def self.available?
          RUBY_PLATFORM.include?("darwin") && Portage::Cli::PaymentMethods.executable?("security")
        end

        # `-U` upserts rather than erroring on a pre-existing account, so
        # re-enrolling under the same id just replaces the secret.
        def write(id, token)
          run("add-generic-password", "-a", id, "-s", SERVICE, "-w", token, "-U")
        end

        def read(id)
          out, status = Open3.capture2("security", "find-generic-password", "-a", id, "-s", SERVICE, "-w")
          status.success? ? out.chomp : nil
        end

        def delete(id)
          run("delete-generic-password", "-a", id, "-s", SERVICE)
        end

        private

        def run(*)
          Open3.capture2("security", *)
          nil
        end
      end
    end
  end
end

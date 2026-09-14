require "open3"

module Portage
  module Cli
    class PaymentMethods
      # Linux Secret Service (GNOME Keyring/KWallet via D-Bus), through the
      # `secret-tool` CLI. Only reachable with a live D-Bus session — the
      # headless/no-session case falls through to EnvBackend instead (see
      # PaymentMethods.detect_backend), never a homegrown fallback store.
      class SecretServiceBackend
        SERVICE = "portage-cli-payment".freeze

        def self.available?
          ENV["DBUS_SESSION_BUS_ADDRESS"].to_s != "" && Portage::Cli::PaymentMethods.executable?("secret-tool")
        end

        # `secret-tool store` reads the secret from stdin rather than argv,
        # so it never shows up in `ps`/shell history.
        def write(id, token)
          Open3.capture2(
            "secret-tool", "store", "--label=Portage payment method #{id}",
            "service", SERVICE, "account", id, stdin_data: token
          )
          nil
        end

        def read(id)
          out, status = Open3.capture2("secret-tool", "lookup", "service", SERVICE, "account", id)
          status.success? ? out.chomp : nil
        end

        def delete(id)
          Open3.capture2("secret-tool", "clear", "service", SERVICE, "account", id)
          nil
        end
      end
    end
  end
end

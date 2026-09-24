require "open3"
require_relative "../payment_methods"

module Portage
  module Cli
    class ProxySettings
      # Resolves `proxy.password_ref` (and any per-hop `password_ref`) the
      # same three-tier way PaymentMethods.detect_backend picks a payment
      # secret store: macOS Keychain, then Linux Secret Service, then
      # nothing in headless mode. Deliberately its own service name rather
      # than PaymentMethods::KeychainBackend/SecretServiceBackend directly —
      # those are scoped to "portage-cli-payment", and their headless tier
      # (EnvBackend#read(_id)) answers *every* id with PORTAGE_PAYMENT_TOKEN
      # regardless of what was asked for, which would make a misconfigured
      # proxy.password_ref silently leak the payment token as a proxy
      # password. A ref that can't be resolved here just comes back nil —
      # ProxySettings turns that into a clear config error rather than
      # sending a proxy request with a literal "password_ref" placeholder.
      module PasswordRef
        SERVICE = "portage-cli-proxy".freeze

        module_function

        def resolve(ref)
          return nil if ref.to_s.strip.empty?
          return keychain(ref) if macos? && Portage::Cli::PaymentMethods.executable?("security")
          return secret_service(ref) if linux_session? && Portage::Cli::PaymentMethods.executable?("secret-tool")

          nil
        end

        def macos? = RUBY_PLATFORM.include?("darwin")

        def linux_session? = ENV["DBUS_SESSION_BUS_ADDRESS"].to_s != ""

        def keychain(ref)
          out, status = Open3.capture2("security", "find-generic-password", "-a", ref, "-s", SERVICE, "-w")
          status.success? ? out.chomp : nil
        end

        def secret_service(ref)
          out, status = Open3.capture2("secret-tool", "lookup", "service", SERVICE, "account", ref)
          status.success? ? out.chomp : nil
        end
      end
    end
  end
end

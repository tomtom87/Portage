require "portage/ucp"
require "portage/ucp/client"
require_relative "homepage_fetch"
require_relative "permissive_authenticator"

module Portage
  module Cli
    # The own-store loopback fallback HandoffReconciler and PaymentMethods
    # share, mirroring Buy's own (#adapter_flow): sniff the platform from
    # the store's homepage and, when that platform's env vars are set,
    # build its adapter and wrap it in a loopback client. A later process
    # must not assume an earlier one's session or credentials still exist,
    # only that the env vars are still set.
    module AdapterSession
      # @param route [Symbol] the Support::Connection route the homepage
      #   fetch goes over (PaymentMethods passes :payment).
      # @return [Portage::Ucp::Client::Session, nil] nil when the platform
      #   isn't recognised, its env is incomplete, or anything fails.
      def self.call(uri, route: :store)
        body, headers = HomepageFetch.call(uri, route: route)
        platform = body && Portage::Ucp::Resolver.detect_platform(body, headers)
        return nil unless platform

        env = Portage::Ucp::Resolver.env_for(platform)
        return nil unless Portage::Ucp::Resolver.missing_env(platform, env).empty?

        adapter = Portage::Ucp::Resolver.build_adapter(platform, env)
        Portage::Ucp::Client.for_adapter(adapter, authenticator: PermissiveAuthenticator.new)
      rescue StandardError
        nil
      end
    end
  end
end

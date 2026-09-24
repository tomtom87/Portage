require "portage/ucp/client"
require_relative "version"
require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # Every request this CLI makes — to a store, a search backend, a
    # payment handler, or a notify webhook — names itself, then the client
    # gem it speaks UCP through, so a merchant reading its logs sees
    # "portage-cli/... portage-ucp-client/... (+https://github.com/...)"
    # rather than Ruby's default and knows where to look.
    #
    # A caller running many agents behind one IP (or one that just wants
    # its own contact info in the string a merchant might grep for) can
    # override it — same Setting precedence as Notifier's webhook URL:
    # PORTAGE_USER_AGENT beats ~/.portage/config.json's "user_agent" key,
    # both of which beat this default. Resolved fresh on every call rather
    # than frozen at load time, so a config.json edit or an ENV change
    # takes effect without restarting whatever's driving this CLI.
    module UserAgent
      DEFAULT = "portage-cli/#{VERSION} #{Portage::Ucp::Client::USER_AGENT}".freeze
      ENV_VAR = "PORTAGE_USER_AGENT".freeze
      CONFIG_KEY = "user_agent".freeze

      module_function

      # @param config [Config]
      # @return [String] never blank — falls back to DEFAULT.
      def value(config: Config.load)
        Setting.resolve(env: ENV_VAR, config: config, config_key: CONFIG_KEY) || DEFAULT
      end

      # @param config [Config]
      # @return [Hash] a fresh header hash, safe for a caller to #merge into.
      def headers(config: Config.load) = { "User-Agent" => value(config: config) }
    end
  end
end

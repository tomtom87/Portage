module Portage
  module Ucp
    # @abstract Pluggable auth contract (§9). Given the MCP server_context for a
    #   tool call, return an auth context (any truthy value) or raise
    #   Portage::Ucp::AuthenticationError. There is deliberately no default that
    #   allows anonymous mutation — an unconfigured server rejects every
    #   mutating capability call (see UNCONFIGURED below). Read-only catalog
    #   calls MAY be left open at the consumer's explicit choice by not
    #   requiring authentication for those specific actions (see
    #   Mcp::Server.build's `mutating_only:`).
    class Authenticator
      def call(_server_context)
        raise NotImplementedError, "#{self.class} must implement #call"
      end
    end

    # The default when no authenticator is configured: rejects every call it
    # is asked to authenticate. Never permissive by default (§9).
    class UnconfiguredAuthenticator < Authenticator
      def call(_server_context)
        raise Portage::Ucp::AuthenticationError,
              "no authenticator configured — mutating capabilities reject all calls until one is set"
      end
    end
  end
end

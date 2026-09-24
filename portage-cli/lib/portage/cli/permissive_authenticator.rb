require "portage/ucp"

module Portage
  module Cli
    # Loopback buy against your own store needs *some* authenticator (§9
    # rejects anonymous mutation by default) — since this process already
    # has this platform's own credentials (that's the gate to even reach the
    # adapter-fallback path, in both Buy and HandoffReconciler), authenticating
    # this local CLI session is reasonable. Shared by both rather than
    # defined once as a nested class of Buy, since HandoffReconciler's own
    # reconnect needs it too and shouldn't reach into Buy's internals for it.
    class PermissiveAuthenticator < Portage::Ucp::Authenticator
      def call(_server_context) = :local_cli
    end
  end
end

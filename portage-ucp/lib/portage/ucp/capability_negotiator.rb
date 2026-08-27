module Portage
  module Ucp
    # Reconciles UCP's capability-version negotiation with MCP's own
    # transport-level capability negotiation (§10) — they answer different
    # questions and both apply regardless of transport:
    # - MCP `initialize` negotiates protocol features (tools/resources/prompts).
    # - This negotiator picks, per capability, which *version* both sides speak:
    #   the platform's advertised versions intersected with the versions this
    #   server (its registry + adapter) actually advertises.
    #
    # Over HTTP the platform's advertised versions come from the `UCP-Agent`
    # header; over stdio there's no header, so they arrive in `initialize`
    # params instead. Either way this class only deals in the parsed version
    # list — transports are responsible for extracting it from their own
    # request shape.
    #
    # §23 step 3: §12 promises a `capability_negotiated` event here, but
    # #negotiate has no call site anywhere in this gem outside its own spec
    # — nothing in the request path (transport `initialize` handling, or
    # otherwise) invokes it yet. Wiring the event would mean building that
    # call site first, which is a bigger change than threading a logger
    # through an existing collaborator; left undone, and cut from §12
    # rather than promised. Revisit once something actually calls #negotiate.
    class CapabilityNegotiator
      def initialize(registry: CapabilityRegistry.default)
        @registry = registry
      end

      # @param adapter [Portage::Ucp::Adapter]
      # @param platform_versions [Hash<String, Array<String>>] capability name =>
      #   versions the platform/agent advertises support for. A capability
      #   absent from this hash falls back to "offer all business-advertised
      #   versions, newest-first" (§10's stdio fallback, applied uniformly).
      # @return [Hash<String, String>] capability name => negotiated version.
      #   A capability with no version in common is omitted, not raised on —
      #   it simply isn't usable for this session.
      def negotiate(adapter:, platform_versions: {})
        @registry.advertised(adapter).each_with_object({}) do |capability, negotiated|
          business_versions = [capability.version]
          offered = platform_versions[capability.name]

          version = offered ? (offered & business_versions).first : business_versions.max
          negotiated[capability.name] = version if version
        end
      end
    end
  end
end

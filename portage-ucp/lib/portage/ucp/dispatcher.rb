module Portage
  module Ucp
    # Accepts a UCP-shaped request (capability + action + arguments), routes it
    # through the CapabilityRegistry to the backing Adapter method, and wraps
    # the result as MCP's dual content/structuredContent output (see §5).
    class Dispatcher
      def initialize(adapter:, registry: CapabilityRegistry.default, logger: Portage::Ucp.configuration.logger)
        @adapter = adapter
        @registry = registry
        @logger = logger
      end

      # @param correlation_id [String, nil] threaded through to the adapter
      #   (via Support::CheckoutState#ucp_observability=) so a
      #   checkout_state_transition event (§12) it emits during this call
      #   carries the same id as the tool_called event that triggered it.
      #   Optional, not correlation_id: required, since Dispatcher.call is
      #   also the conformance kit's (lib/portage/ucp/rspec.rb) and specs'
      #   direct entry point, outside any MCP request (§23).
      def call(capability:, action:, arguments: {}, correlation_id: nil)
        capability_definition = @registry.find(capability)
        raise UnknownCapabilityError, capability if capability_definition.nil?

        raise CapabilityNotAdvertisedError, capability unless capability_definition.advertised_for?(@adapter)

        method_name = capability_definition.actions[action]
        raise UnknownActionError, action if method_name.nil?

        Portage::Ucp::PaymentTokenGuard.validate!(arguments[:payment_token]) if arguments.key?(:payment_token)

        @adapter.ucp_observability = [@logger, correlation_id] if @adapter.respond_to?(:ucp_observability=)
        result = @adapter.public_send(method_name, **arguments)
        wrap(capability, result)
      end

      private

      def wrap(capability_name, result)
        unless result.respond_to?(:to_wire_h)
          return { content: [{ type: "text", text: result.inspect }], structuredContent: result }
        end

        payload = Portage::Ucp::WireEnvelope.wrap(capability_name, result.to_wire_h)
        { content: [{ type: "text", text: payload.inspect }], structuredContent: payload }
      end
    end
  end
end

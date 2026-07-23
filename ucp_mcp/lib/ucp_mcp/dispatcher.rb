module UcpMcp
  # Accepts a UCP-shaped request (capability + action + arguments), routes it
  # through the CapabilityRegistry to the backing Adapter method, and wraps
  # the result as MCP's dual content/structuredContent output (see §5).
  class Dispatcher
    def initialize(adapter:, registry: CapabilityRegistry.default)
      @adapter = adapter
      @registry = registry
    end

    def call(capability:, action:, arguments: {})
      capability_definition = @registry.find(capability)
      raise UnknownCapabilityError, capability if capability_definition.nil?

      unless capability_definition.advertised_for?(@adapter)
        raise CapabilityNotAdvertisedError, capability
      end

      method_name = capability_definition.actions[action]
      raise UnknownActionError, action if method_name.nil?

      result = @adapter.public_send(method_name, **arguments)
      wrap(result)
    end

    private

    def wrap(result)
      { content: [{ type: "text", text: result.inspect }], structuredContent: result }
    end
  end
end

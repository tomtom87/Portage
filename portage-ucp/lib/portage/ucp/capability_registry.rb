module Portage
  module Ucp
    class CapabilityRegistry
      def initialize(capabilities:)
        @capabilities = capabilities
      end

      def self.default
        new(capabilities: Portage::Ucp::Capabilities::ALL)
      end

      def advertised(adapter)
        @capabilities.select { |capability| capability.advertised_for?(adapter) }
      end

      def find(name)
        @capabilities.find { |capability| capability.name == name }
      end
    end
  end
end

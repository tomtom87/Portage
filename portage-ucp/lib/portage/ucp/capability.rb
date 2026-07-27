module Portage
  module Ucp
    # A named, versioned UCP capability (e.g. "dev.ucp.shopping.catalog") mapping
    # UCP action names to the Adapter methods that back them.
    class Capability
      attr_reader :name, :version, :actions

      def initialize(name:, version:, actions:)
        @name = name
        @version = version
        @actions = actions
      end

      # Advertised only if at least one backing Adapter method is overridden —
      # see Portage::Ucp::Adapter for why (contract can grow without breaking adapters).
      def advertised_for?(adapter)
        actions.values.any? { |method_name| overridden?(adapter, method_name) }
      end

      private

      def overridden?(adapter, method_name)
        adapter.class.instance_method(method_name).owner != Portage::Ucp::Adapter
      end
    end
  end
end

module Portage
  module Ucp
    # A named, versioned UCP capability (e.g. "dev.ucp.shopping.catalog") mapping
    # UCP action names to the Adapter methods that back them.
    class Capability
      attr_reader :name, :version, :actions

      # `predicate:` is for extension capabilities like
      # dev.ucp.shopping.discount and dev.ucp.shopping.fulfillment that add a
      # param to an existing action rather than an action of their own —
      # there's no dedicated method whose override signals support, so the
      # adapter exposes a boolean method instead and the capability asks it
      # directly rather than inspecting `actions`.
      def initialize(name:, version:, actions:, predicate: nil)
        @name = name
        @version = version
        @actions = actions
        @predicate = predicate
      end

      # Advertised if the predicate says so, or (for ordinary action-based
      # capabilities) if at least one backing Adapter method is overridden —
      # see Portage::Ucp::Adapter for why (contract can grow without breaking adapters).
      def advertised_for?(adapter)
        return adapter.public_send(@predicate) if @predicate

        actions.values.any? { |method_name| overridden?(adapter, method_name) }
      end

      private

      def overridden?(adapter, method_name)
        adapter.class.instance_method(method_name).owner != Portage::Ucp::Adapter
      end
    end
  end
end

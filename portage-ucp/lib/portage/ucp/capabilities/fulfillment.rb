module Portage
  module Ucp
    module Capabilities
      # schemas/shopping/fulfillment.json — extends Checkout with a
      # `fulfillment` field (shipping/pickup methods, groups, destinations)
      # rather than adding actions of its own, same predicate-based
      # advertisement as DISCOUNT above.
      FULFILLMENT = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.fulfillment",
        version: "1",
        actions: {},
        predicate: :fulfillment_supported?
      )
    end
  end
end

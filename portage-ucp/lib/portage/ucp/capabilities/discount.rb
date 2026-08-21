module Portage
  module Ucp
    module Capabilities
      # schemas/shopping/discount.json — extends Cart/Checkout with a
      # `discounts` field rather than adding actions of its own, so `actions`
      # is empty and advertisement runs off Adapter#discount_codes_supported?
      # instead (see Capability#advertised_for?).
      DISCOUNT = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.discount",
        version: "1",
        actions: {},
        predicate: :discount_codes_supported?
      )
    end
  end
end

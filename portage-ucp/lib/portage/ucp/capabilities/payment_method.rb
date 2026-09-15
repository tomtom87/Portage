module Portage
  module Ucp
    module Capabilities
      # Portage-only extensions, not part of the UCP spec (no ucp.dev
      # reverse-domain meaning to borrow), same posture as
      # Capabilities::PAYMENT_ENROLLMENT/REORDER. Advertised only if the
      # adapter overrides at least one of its own action methods. Kept as
      # two capabilities (payment methods vs. addresses) rather than one,
      # per design-log §16/§22 item 7's "ship together, but they're
      # separate concerns" — a consumer can still gate them independently.
      PAYMENT_METHOD = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.payment_method",
        version: "1",
        actions: { "save_payment_method" => :save_payment_method,
                   "list_payment_methods" => :list_payment_methods,
                   "delete_payment_method" => :delete_payment_method }
      )

      SAVED_ADDRESS = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.saved_address",
        version: "1",
        actions: { "save_address" => :save_address,
                   "list_addresses" => :list_addresses,
                   "delete_address" => :delete_address }
      )
    end
  end
end

module Portage
  module Ucp
    module Capabilities
      # Portage-only extension, not part of the UCP spec. Kept separate from
      # PAYMENT_METHOD/SAVED_ADDRESS: this is the erasure duty over *both*
      # of those plus the linked identity, not a peer capability alongside
      # them (design-log §22 item 7).
      SHOPPER_DATA = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.shopper_data",
        version: "1",
        actions: { "delete_shopper_data" => :delete_shopper_data }
      )
    end
  end
end

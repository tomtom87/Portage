module Portage
  module Ucp
    module Capabilities
      # Portage-only extension, not part of the UCP spec (no ucp.dev
      # reverse-domain meaning to borrow), same posture as Capabilities::REORDER.
      # Advertised only if the adapter overrides Adapter#create_payment_enrollment
      # — an adapter with no real gateway support for it simply never shows it
      # in the manifest (see docs/plans/agentic-payments.md Phase 1).
      PAYMENT_ENROLLMENT = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.payment_enrollment",
        version: "1",
        actions: { "create_payment_enrollment" => :create_payment_enrollment,
                   "get_payment_enrollment" => :get_payment_enrollment }
      )
    end
  end
end

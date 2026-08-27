module Portage
  module Ucp
    module Capabilities
      # Portage-only extension, not part of the UCP spec (no ucp.dev
      # reverse-domain meaning to borrow), so this is namespaced under the
      # gem's own name instead of "dev.ucp.*". Advertised only if the
      # adapter overrides Adapter#reorder, same as every other capability
      # (Capability#advertised_for?) — an adapter that hasn't implemented it
      # simply never shows it in the manifest.
      REORDER = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.reorder",
        version: "1",
        actions: { "reorder" => :reorder }
      )
    end
  end
end

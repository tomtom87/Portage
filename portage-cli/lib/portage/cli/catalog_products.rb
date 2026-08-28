module Portage
  module Cli
    # Unwraps whatever shape a catalog search call actually returns.
    #
    # Every call that goes through a Portage::Ucp::Client::Session — native
    # remote stores and the own-store loopback session built via
    # Client.for_adapter alike — passes through Dispatcher#wrap, which calls
    # `to_wire_h` on the result before handing it back. So a Session's
    # `search_catalog` always comes back as the wire-shaped envelope
    # `{"ucp" => ..., "products" => [...]}`, never a bare array and never a
    # raw struct.
    #
    # The one exception is Buy's own-store catalog-only path
    # (`Buy#catalog_only_adapter`), which calls `Adapter#search_catalog`
    # directly — no Session, no Dispatcher — and gets back the real
    # `Portage::Ucp::CatalogSearchResult` the adapter built.
    module CatalogProducts
      module_function

      def from(result)
        case result
        when Portage::Ucp::CatalogSearchResult then result.products
        when Hash then Array(result["products"])
        else Array(result)
        end
      end
    end
  end
end

module Portage
  module Ucp
    module Support
      # schemas/shopping/types/order_line_item.json's `status` derived from
      # the line's own quantity tracking, for platforms that report
      # per-line fulfilled quantities.
      #
      # Platforms whose core has no per-line fulfillment (WooCommerce,
      # BigCommerce) instead map their order-level status enum onto this same
      # vocabulary with a table of their own, then hand every line the same
      # coarse value — those tables stay in their gems, since the enums are
      # platform-specific.
      module LineItemStatus
        module_function

        def derive(total:, fulfilled:)
          return "removed" if total.zero?
          return "fulfilled" if fulfilled == total
          return "partial" if fulfilled.positive?

          "processing"
        end
      end
    end
  end
end

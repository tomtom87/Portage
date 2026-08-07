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
      # coarse value. The tables themselves stay in their gems — the enums
      # are platform-specific — but #from_table and #fulfilled_quantity are
      # what those gems do with them, and that part is not.
      module LineItemStatus
        module_function

        def derive(total:, fulfilled:)
          return "removed" if total.zero?
          return "fulfilled" if fulfilled == total
          return "partial" if fulfilled.positive?

          "processing"
        end

        # "processing" is the fallback for an unmapped platform status on
        # purpose: every table here is written against a documented enum that
        # the platform is free to extend, and an order in a status we've never
        # seen is far more likely to be in flight than cancelled or delivered.
        # Guessing "removed" would tell a caller an order is dead when it
        # isn't.
        def from_table(table, key)
          table.fetch(key, "processing")
        end

        # Platforms without per-line fulfillment still owe
        # schemas/shopping/types/order_line_item.json a `fulfilled` count, so
        # the order-level status stands in for it: all of the line or none.
        def fulfilled_quantity(status, quantity)
          status == "fulfilled" ? quantity : 0
        end
      end
    end
  end
end

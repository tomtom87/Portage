require "bigdecimal"

module Portage
  module Ucp
    module Support
      # Money arithmetic every adapter gem's Mapper needs. UCP wire shapes
      # carry integer minor units (schemas/shopping/types/total.json), while
      # commerce APIs hand back either decimal strings ("12.50") or already-
      # minor-unit integers-as-strings ("1250") — one conversion per shape,
      # defined once here rather than re-derived per gem.
      #
      # Mappers keep their own one-line `money`/`minor_units` wrappers around
      # these: the wrapper's signature is platform-shaped (a GraphQL price
      # node, an amount plus a threaded-in currency), only the arithmetic is
      # shared.
      module Amounts
        module_function

        # Decimal-string (or numeric) major units -> integer minor units.
        # nil/"" is 0 rather than an exception: several APIs omit a money
        # field entirely instead of sending a zero.
        def decimal_to_minor(amount)
          return 0 if amount.nil? || amount == ""

          (BigDecimal(amount.to_s) * 100).to_i
        end

        # Already-minor-unit values (e.g. WooCommerce's Store API sends "500"
        # for $5.00, tagged with its own `currency_minor_unit`) — an integer
        # parse, no BigDecimal scaling.
        def subunits_to_minor(amount)
          return 0 if amount.nil?

          amount.to_i
        end

        def money(amount, currency)
          Portage::Ucp::Money.new(amount_minor: decimal_to_minor(amount), currency: currency)
        end
      end
    end
  end
end

module Portage
  module Ucp
    module Support
      # Builders for the two Total-array shapes the shopping schemas use.
      # Both encode rules that were previously restated in every mapper: the
      # top-level array is exactly one subtotal plus one total with an
      # optional tax entry between them, and a line item's array is the same
      # amount reported twice unless the line carries its own discount.
      module Totals
        module_function

        # Top-level cost breakdown for a Cart/Checkout/Order. The tax entry
        # is emitted only when positive — a zero-tax order shouldn't claim a
        # tax line it doesn't have.
        def summary(subtotal:, total:, tax: nil)
          entries = [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal)]
          entries << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax&.positive?
          entries << Portage::Ucp::Total.new(type: "total", amount: total)
          entries
        end

        # A line item's own totals. `total` defaults to `subtotal` for the
        # common case where nothing discounts the line.
        def line(subtotal, total = subtotal)
          [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
           Portage::Ucp::Total.new(type: "total", amount: total)]
        end

        # The reader for the arrays above: the amount of the first entry of
        # `type`, or nil when there is none. Takes `Total` value objects or
        # their wire hashes (string- or symbol-keyed), since callers hold
        # either — an adapter's own result, or a checkout read back through
        # a Session.
        def amount(totals, type: "total")
          entry = Array(totals).find { |total| field(total, :type) == type }
          entry && field(entry, :amount)
        end

        def field(total, name)
          total.is_a?(Hash) ? total.fetch(name.to_s) { total[name] } : total.public_send(name)
        end
        private_class_method :field
      end
    end
  end
end

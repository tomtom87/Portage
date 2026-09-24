module Portage
  module Cli
    class HandoffReconciler
      # Adapts a wire hash (from #get_checkout/#get_order) to what
      # OrderLedger#record/PurchaseJournal#record_checkout duck-type against
      # (Portage::Ucp::Order/Checkout value objects) — see
      # docs/plans/handoff-reconcile.md, "The journal needs a
      # hash-to-value-object step". Deliberately not a second, parallel
      # entry shape: both still go through PurchaseJournal#record_checkout /
      # OrderLedger#record's own logic (`to_wire_h`) — these just wrap the
      # already-wire-shaped hash to answer the handful of methods each one
      # calls.
      WireOrder = Struct.new(:wire) do
        def id = wire["id"]
        def to_wire_h = wire
      end

      WireCheckout = Struct.new(:wire) do
        def currency = wire["currency"]
        def order = wire["order"] && WireOrderRef.new(wire["order"])

        def line_items
          Array(wire["line_items"]).map { |li| WireLineItem.new(li) }
        end
      end

      WireOrderRef = Struct.new(:wire) do
        def id = wire["id"]
      end

      WireLineItem = Struct.new(:wire) do
        def item = WireItem.new(wire["item"] || {})
        def quantity = wire["quantity"]

        def totals
          Array(wire["totals"]).map { |t| WireTotal.new(t) }
        end
      end

      WireItem = Struct.new(:wire) do
        def id = wire["id"]
      end

      WireTotal = Struct.new(:wire) do
        def type = wire["type"]
        def amount = wire["amount"]
      end
    end
  end
end

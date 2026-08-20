module Portage
  module Ucp
    # Internal arithmetic helper only — never appears in a wire shape directly.
    Money = Data.define(:amount_minor, :currency)

    Product = Data.define(:id, :title, :description, :price, :available, :variants, :url)

    # One cost-breakdown entry (schemas/shopping/types/total.json). `amount` is a
    # signed integer in the parent object's currency's minor units.
    Total = Data.define(:type, :amount, :display_text) do
      def initialize(type:, amount:, display_text: nil) = super

      def to_wire_h
        h = { "type" => type, "amount" => amount }
        h["display_text"] = display_text if display_text
        h
      end
    end

    # Product identity on a line item (schemas/shopping/types/item.json). `price`
    # is a bare integer minor-unit amount — the parent object's currency applies.
    Item = Data.define(:id, :title, :price, :image_url) do
      def initialize(id:, title:, price:, image_url: nil) = super

      def to_wire_h
        h = { "id" => id, "title" => title, "price" => price }
        h["image_url"] = image_url if image_url
        h
      end
    end

    # schemas/shopping/types/line_item.json — id/item/quantity/totals, not a
    # flat product_id/unit_price/total triple.
    LineItem = Data.define(:id, :item, :quantity, :totals) do
      def to_wire_h
        { "id" => id, "item" => item.to_wire_h, "quantity" => quantity,
          "totals" => totals.map(&:to_wire_h) }
      end
    end

    # schemas/shopping/types/link.json
    Link = Data.define(:type, :url, :title) do
      def initialize(type:, url:, title: nil) = super

      def to_wire_h
        h = { "type" => type, "url" => url }
        h["title"] = title if title
        h
      end
    end

    # schemas/shopping/discount.json#/$defs/applied_discount — requires title/
    # amount. `code` is omitted for automatic discounts; `allocations` (the
    # per-target breakdown) is left empty rather than guessed at by adapters
    # that can't source it from their platform.
    # `allocation_method` maps to the wire key "method" — bare `:method` as a
    # Data.define member would shadow Kernel#method.
    AppliedDiscount = Data.define(:title, :amount, :code, :automatic, :allocation_method, :priority, :provisional,
                                  :eligibility, :allocations) do
      def initialize(title:, amount:, code: nil, automatic: false, allocation_method: nil, priority: nil,
                     provisional: false, eligibility: nil, allocations: [])
        super
      end

      def to_wire_h
        h = { "title" => title, "amount" => amount }
        { code: "code", automatic: "automatic", allocation_method: "method", priority: "priority",
          provisional: "provisional", eligibility: "eligibility" }.each do |attr, key|
          h[key] = public_send(attr) if public_send(attr)
        end
        h["allocations"] = allocations if allocations.any?
        h
      end
    end

    # schemas/shopping/discount.json#/$defs/discounts_object — `codes` is the
    # request-side input (case-insensitive, full-replacement — send [] to
    # clear); `applied` is the response-side result. Both optional, so a Cart/
    # Checkout with no discount activity omits the whole field (see Cart/
    # Checkout#to_wire_h below), same posture as Order#adjustments.
    Discounts = Data.define(:codes, :applied) do
      def initialize(codes: [], applied: []) = super

      def empty? = codes.empty? && applied.empty?

      def to_wire_h
        h = {}
        h["codes"] = codes unless codes.empty?
        h["applied"] = applied.map(&:to_wire_h) unless applied.empty?
        h
      end
    end

    # schemas/shopping/cart.json — requires ucp/id/line_items/currency/totals.
    # The "ucp" envelope is added centrally by Portage::Ucp::WireEnvelope, not stored
    # on the value object itself.
    # `discounts` is the dev.ucp.shopping.discount extension (optional on both
    # cart.json and its own schema) — omitted from the wire payload when empty,
    # same as Order#adjustments.
    Cart = Data.define(:id, :line_items, :currency, :totals, :discounts) do
      def initialize(id:, line_items:, currency:, totals:, discounts: Discounts.new) = super

      def to_wire_h
        h = { "id" => id, "line_items" => line_items.map(&:to_wire_h), "currency" => currency,
              "totals" => totals.map(&:to_wire_h) }
        h["discounts"] = discounts.to_wire_h unless discounts.empty?
        h
      end
    end

    # schemas/shopping/types/order_confirmation.json — requires id/permalink_url.
    # Carried on Checkout#order once complete_checkout actually produces an
    # order; nil until then.
    OrderConfirmation = Data.define(:id, :permalink_url, :label) do
      def initialize(id:, permalink_url:, label: nil) = super

      def to_wire_h
        h = { "id" => id, "permalink_url" => permalink_url }
        h["label"] = label if label
        h
      end
    end

    # schemas/shopping/checkout.json — requires ucp/id/line_items/status/
    # currency/totals/links. `status` is the real enum (incomplete,
    # requires_escalation, ready_for_complete, complete_in_progress, completed,
    # canceled) — not the old ad hoc "pending"/"completed" strings. `order` is
    # the schema's optional order_confirmation — set once complete_checkout
    # actually produces an order, nil otherwise.
    # `discounts` — same dev.ucp.shopping.discount extension as Cart, above.
    Checkout = Data.define(:id, :status, :line_items, :currency, :totals, :links, :order, :discounts) do
      def initialize(id:, status:, line_items:, currency:, totals:, links:, order: nil, discounts: Discounts.new)
        super
      end

      def to_wire_h
        h = { "id" => id, "status" => status, "line_items" => line_items.map(&:to_wire_h),
              "currency" => currency, "totals" => totals.map(&:to_wire_h), "links" => links.map(&:to_wire_h) }
        h["order"] = order.to_wire_h if order
        h["discounts"] = discounts.to_wire_h unless discounts.empty?
        h
      end
    end

    # schemas/shopping/types/order_line_item.json — distinct from LineItem:
    # quantity is {original,total,fulfilled} tracking, plus a derived status
    # enum, not a bare integer.
    OrderLineItem = Data.define(:id, :item, :quantity, :totals, :status, :parent_id) do
      def initialize(id:, item:, quantity:, totals:, status:, parent_id: nil) = super

      def to_wire_h
        q = { "total" => quantity[:total], "fulfilled" => quantity[:fulfilled] }
        q["original"] = quantity[:original] if quantity[:original]
        h = { "id" => id, "item" => item.to_wire_h, "quantity" => q, "totals" => totals.map(&:to_wire_h),
              "status" => status }
        h["parent_id"] = parent_id if parent_id
        h
      end
    end

    # schemas/shopping/types/expectation.json — buyer-facing delivery grouping.
    Expectation = Data.define(:id, :line_items, :method_type, :destination, :description, :fulfillable_on) do
      def initialize(id:, line_items:, method_type:, destination:, description: nil, fulfillable_on: nil) = super

      def to_wire_h
        h = { "id" => id, "line_items" => line_items, "method_type" => method_type, "destination" => destination }
        h["description"] = description if description
        h["fulfillable_on"] = fulfillable_on if fulfillable_on
        h
      end
    end

    # schemas/shopping/types/fulfillment_event.json — append-only shipment event.
    FulfillmentEvent = Data.define(:id, :occurred_at, :type, :line_items, :tracking_number, :tracking_url, :carrier,
                                   :description) do
      def initialize(id:, occurred_at:, type:, line_items:, tracking_number: nil, tracking_url: nil, carrier: nil,
                     description: nil)
        super
      end

      def to_wire_h
        h = { "id" => id, "occurred_at" => occurred_at, "type" => type, "line_items" => line_items }
        h["tracking_number"] = tracking_number if tracking_number
        h["tracking_url"] = tracking_url if tracking_url
        h["carrier"] = carrier if carrier
        h["description"] = description if description
        h
      end
    end

    # schemas/shopping/order.json#/properties/fulfillment — no required inner
    # fields (expectations/events are both optional), so an adapter that
    # doesn't model buyer-facing delivery expectations yet can pass
    # Fulfillment.new and still be schema-conformant.
    Fulfillment = Data.define(:expectations, :events) do
      def initialize(expectations: [], events: []) = super

      def to_wire_h
        { "expectations" => expectations.map(&:to_wire_h), "events" => events.map(&:to_wire_h) }
      end
    end

    # schemas/shopping/types/adjustment.json — post-order event independent of
    # fulfillment (refund, return, credit, price_adjustment, dispute,
    # cancellation, ...). `status` is pending/completed/failed.
    Adjustment = Data.define(:id, :type, :occurred_at, :status, :line_items, :totals, :description) do
      def initialize(id:, type:, occurred_at:, status:, line_items: nil, totals: nil, description: nil) = super

      def to_wire_h
        h = { "id" => id, "type" => type, "occurred_at" => occurred_at, "status" => status }
        h["line_items"] = line_items if line_items
        h["totals"] = totals.map(&:to_wire_h) if totals
        h["description"] = description if description
        h
      end
    end

    # schemas/shopping/order.json — requires ucp/id/checkout_id/permalink_url/
    # line_items/fulfillment/currency/totals. `adjustments` is optional —
    # omitted from the wire payload when empty.
    Order = Data.define(:id, :checkout_id, :permalink_url, :line_items, :fulfillment, :currency, :totals,
                        :adjustments) do
      def initialize(id:, checkout_id:, permalink_url:, line_items:, fulfillment:, currency:, totals:,
                     adjustments: [])
        super
      end

      def to_wire_h
        h = { "id" => id, "checkout_id" => checkout_id, "permalink_url" => permalink_url,
              "line_items" => line_items.map(&:to_wire_h), "fulfillment" => fulfillment.to_wire_h,
              "currency" => currency, "totals" => totals.map(&:to_wire_h) }
        h["adjustments"] = adjustments.map(&:to_wire_h) unless adjustments.empty?
        h
      end
    end

    Identity = Data.define(:subject, :email, :linked_at)
  end
end

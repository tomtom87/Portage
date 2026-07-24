module UcpMcp
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

  # schemas/shopping/cart.json — requires ucp/id/line_items/currency/totals.
  # The "ucp" envelope is added centrally by UcpMcp::WireEnvelope, not stored
  # on the value object itself.
  Cart = Data.define(:id, :line_items, :currency, :totals) do
    def to_wire_h
      { "id" => id, "line_items" => line_items.map(&:to_wire_h), "currency" => currency,
        "totals" => totals.map(&:to_wire_h) }
    end
  end

  # schemas/shopping/checkout.json — requires ucp/id/line_items/status/
  # currency/totals/links. `status` is the real enum (incomplete,
  # requires_escalation, ready_for_complete, complete_in_progress, completed,
  # canceled) — not the old ad hoc "pending"/"completed" strings.
  Checkout = Data.define(:id, :status, :line_items, :currency, :totals, :links) do
    def to_wire_h
      { "id" => id, "status" => status, "line_items" => line_items.map(&:to_wire_h),
        "currency" => currency, "totals" => totals.map(&:to_wire_h), "links" => links.map(&:to_wire_h) }
    end
  end

  # schemas/shopping/order.json. NOTE: not fully spec-conformant yet — the
  # real schema also requires checkout_id/permalink_url/fulfillment, and its
  # line items are a distinct, richer order_line_item shape (quantity as
  # {original,total,fulfilled} + a status enum), not this LineItem. Only the
  # envelope + totals-array parity fixes from this pass are applied here;
  # the rest is tracked as a separate, explicitly-known follow-up.
  Order = Data.define(:id, :status, :line_items, :currency, :totals, :placed_at) do
    def to_wire_h
      { "id" => id, "status" => status, "line_items" => line_items.map(&:to_wire_h),
        "currency" => currency, "totals" => totals.map(&:to_wire_h), "placed_at" => placed_at }
    end
  end

  Identity = Data.define(:subject, :email, :linked_at)
end

module Portage
  module Ucp
    # Internal arithmetic helper only — never appears in a wire shape directly.
    # Cart/Checkout/Order totals are bare minor-unit integers (Total#amount)
    # once they reach a value object; Money exists so Support::Amounts has
    # somewhere to hand back both the minor-unit amount and its currency
    # together mid-conversion. Product/Variant carry currency-bearing wire
    # fields directly (Price, below) rather than through Money.
    Money = Data.define(:amount_minor, :currency)

    # schemas/shopping/types/price.json — the wire-shape counterpart to Money
    # above: an integer minor-unit amount paired with its currency, appearing
    # directly in Product/Variant payloads.
    Price = Data.define(:amount, :currency) do
      def to_wire_h = { "amount" => amount, "currency" => currency }
    end

    # schemas/shopping/types/price_range.json
    PriceRange = Data.define(:min, :max) do
      def to_wire_h = { "min" => min.to_wire_h, "max" => max.to_wire_h }
    end

    # schemas/shopping/types/description.json — the spec requires at least
    # one of plain/html/markdown; that's a request-time authoring concern
    # this value object doesn't enforce, same posture as PostalAddress
    # leaving every field optional.
    Description = Data.define(:plain, :html, :markdown) do
      def initialize(plain: nil, html: nil, markdown: nil) = super

      def to_wire_h = { "plain" => plain, "html" => html, "markdown" => markdown }.compact
    end

    # schemas/shopping/types/category.json
    Category = Data.define(:value, :taxonomy) do
      def initialize(value:, taxonomy: nil) = super

      def to_wire_h = { "value" => value, "taxonomy" => taxonomy }.compact
    end

    # schemas/shopping/types/media.json
    Media = Data.define(:type, :url, :alt_text, :width, :height) do
      def initialize(type:, url:, alt_text: nil, width: nil, height: nil) = super

      def to_wire_h
        { "type" => type, "url" => url, "alt_text" => alt_text, "width" => width, "height" => height }.compact
      end
    end

    # schemas/shopping/types/option_value.json — a selectable value for a
    # ProductOption (e.g. "Blue" under "Color").
    OptionValue = Data.define(:id, :label) do
      def initialize(label:, id: nil) = super

      def to_wire_h = { "id" => id, "label" => label }.compact
    end

    # schemas/shopping/types/product_option.json
    ProductOption = Data.define(:name, :values) do
      def to_wire_h = { "name" => name, "values" => values.map(&:to_wire_h) }
    end

    # schemas/shopping/types/selected_option.json — which OptionValue a
    # Variant actually carries for a given option (e.g. Size: Large).
    SelectedOption = Data.define(:name, :id, :label) do
      def initialize(name:, label:, id: nil) = super

      def to_wire_h = { "name" => name, "id" => id, "label" => label }.compact
    end

    # schemas/shopping/types/rating.json
    Rating = Data.define(:value, :scale_max, :scale_min, :count) do
      def initialize(value:, scale_max:, scale_min: 1, count: nil) = super

      def to_wire_h
        { "value" => value, "scale_min" => scale_min, "scale_max" => scale_max, "count" => count }.compact
      end
    end

    # schemas/shopping/types/variant.json — a purchasable variant of a
    # Product. `id` is what LineItem#item.id actually references at
    # checkout, not Product#id.
    # `barcodes` and `availability` are left as plain wire-shaped hashes
    # (`{"type" =>, "value" =>}` / `{"available" =>, "status" =>}`) rather
    # than their own Data types — both are simple, spec doesn't name them as
    # standalone $refs, and the parent's `to_wire_h` needs them exactly as
    # given, same posture as Adjustment#line_items' inline hashes.
    Variant = Data.define(:id, :title, :description, :price, :sku, :barcodes, :list_price, :availability, :options,
                          :media, :tags, :metadata) do
      def initialize(id:, title:, description:, price:, sku: nil, barcodes: [], list_price: nil, availability: nil,
                     options: [], media: [], tags: [], metadata: nil)
        super
      end

      def to_wire_h
        { "id" => id, "title" => title, "description" => description.to_wire_h,
          "price" => price.to_wire_h }.merge(optional_wire_h)
      end

      private

      def optional_wire_h
        h = { "sku" => sku, "list_price" => list_price&.to_wire_h, "availability" => availability }.compact
        h["barcodes"] = barcodes unless barcodes.empty?
        h["options"] = options.map(&:to_wire_h) unless options.empty?
        h["media"] = media.map(&:to_wire_h) unless media.empty?
        h["tags"] = tags unless tags.empty?
        h["metadata"] = metadata if metadata
        h
      end
    end

    # schemas/shopping/types/product.json — requires id/title/description/
    # price_range/variants (variants minItems: 1). `metadata` is the spec's
    # own sanctioned extension point for business-defined custom data
    # (Shopify/Wix metafields etc.) — see Portage::Ucp::Shopify.configure's
    # metadata_field.
    Product = Data.define(:id, :title, :description, :price_range, :variants, :handle, :url, :categories,
                          :list_price_range, :media, :options, :tags, :metadata, :rating) do
      def initialize(id:, title:, description:, price_range:, variants:, handle: nil, url: nil, categories: [],
                     list_price_range: nil, media: [], options: [], tags: [], metadata: nil, rating: nil)
        super
      end

      def to_wire_h
        { "id" => id, "title" => title, "description" => description.to_wire_h,
          "price_range" => price_range.to_wire_h, "variants" => variants.map(&:to_wire_h) }.merge(optional_wire_h)
      end

      private

      def optional_wire_h
        h = { "handle" => handle, "url" => url, "list_price_range" => list_price_range&.to_wire_h,
              "metadata" => metadata, "rating" => rating&.to_wire_h }.compact
        h["categories"] = categories.map(&:to_wire_h) unless categories.empty?
        h["media"] = media.map(&:to_wire_h) unless media.empty?
        h["options"] = options.map(&:to_wire_h) unless options.empty?
        h["tags"] = tags unless tags.empty?
        h
      end
    end

    # schemas/shopping/catalog_search.json#/$defs/search_response — the
    # container Adapter#search_catalog actually returns; `products` alone
    # isn't schema-conformant (search_response requires `ucp` + `products` at
    # the top level, not a bare array). `messages` entries are left as plain
    # wire-shaped hashes, same rationale as Variant#barcodes above.
    CatalogSearchResult = Data.define(:products, :messages) do
      def initialize(products:, messages: []) = super

      def to_wire_h
        h = { "products" => products.map(&:to_wire_h) }
        h["messages"] = messages unless messages.empty?
        h
      end
    end

    # schemas/shopping/catalog_lookup.json#/$defs/get_product_response — the
    # container Adapter#get_product returns when the product is found (nil
    # otherwise, same not-found posture as get_cart/get_checkout/get_order).
    # Doesn't model detail_product's `selected`/`options` availability-signal
    # extension (interactive variant narrowing) — Adapter#get_product's
    # signature has no `selected:`/`preferences:` params to source it from
    # yet; unresearched, same status as design-log §16's other backlog items.
    ProductDetail = Data.define(:product) do
      def to_wire_h = { "product" => product.to_wire_h }
    end

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

    # schemas/shopping/types/postal_address.json — every field optional, so a
    # partial address (e.g. locality/region/country only, before a full
    # street address is known) is still schema-conformant.
    PostalAddress = Data.define(:extended_address, :street_address, :address_locality, :address_region,
                                :address_country, :postal_code, :first_name, :last_name, :phone_number) do
      def initialize(extended_address: nil, street_address: nil, address_locality: nil, address_region: nil,
                     address_country: nil, postal_code: nil, first_name: nil, last_name: nil, phone_number: nil)
        super
      end

      def to_wire_h
        { "extended_address" => extended_address, "street_address" => street_address,
          "address_locality" => address_locality, "address_region" => address_region,
          "address_country" => address_country, "postal_code" => postal_code, "first_name" => first_name,
          "last_name" => last_name, "phone_number" => phone_number }.compact
      end
    end

    # schemas/shopping/types/shipping_destination.json — postal_address plus a
    # destination id (one of fulfillment.json's two FulfillmentDestination
    # shapes, alongside RetailLocation below).
    ShippingDestination = Data.define(:id, :address) do
      def to_wire_h = address.to_wire_h.merge("id" => id)
    end

    # schemas/shopping/types/retail_location.json — the pickup counterpart to
    # ShippingDestination; only `address` is optional.
    RetailLocation = Data.define(:id, :name, :address) do
      def initialize(id:, name:, address: nil) = super

      def to_wire_h
        h = { "id" => id, "name" => name }
        h["address"] = address.to_wire_h if address
        h
      end
    end

    # schemas/shopping/types/fulfillment_option.json — a single priced choice
    # within a FulfillmentGroup (e.g. "Standard Shipping $5", "Express $15").
    FulfillmentOption = Data.define(:id, :title, :totals, :description, :carrier, :earliest_fulfillment_time,
                                    :latest_fulfillment_time) do
      def initialize(id:, title:, totals:, description: nil, carrier: nil, earliest_fulfillment_time: nil,
                     latest_fulfillment_time: nil)
        super
      end

      def to_wire_h
        h = { "id" => id, "title" => title, "totals" => totals.map(&:to_wire_h) }
        h["description"] = description if description
        h["carrier"] = carrier if carrier
        h["earliest_fulfillment_time"] = earliest_fulfillment_time if earliest_fulfillment_time
        h["latest_fulfillment_time"] = latest_fulfillment_time if latest_fulfillment_time
        h
      end
    end

    # schemas/shopping/types/fulfillment_group.json — a merchant-generated
    # package of line items; the agent sets `selected_option_id` on update to
    # choose a shipping/pickup rate for that package.
    FulfillmentGroup = Data.define(:id, :line_item_ids, :options, :selected_option_id) do
      def initialize(id:, line_item_ids:, options: [], selected_option_id: nil) = super

      def to_wire_h
        { "id" => id, "line_item_ids" => line_item_ids, "options" => options.map(&:to_wire_h),
          "selected_option_id" => selected_option_id }
      end
    end

    # schemas/shopping/types/fulfillment_method.json — shipping or pickup for
    # a subset of line items. The agent submits `type`/`line_item_ids` on
    # create; the merchant fills in `destinations`/`groups` for the agent to
    # then select `selected_destination_id` and each group's
    # `selected_option_id` on update.
    FulfillmentMethod = Data.define(:id, :type, :line_item_ids, :destinations, :selected_destination_id, :groups) do
      def initialize(id:, type:, line_item_ids:, destinations: [], selected_destination_id: nil, groups: [])
        super
      end

      def to_wire_h
        h = { "id" => id, "type" => type, "line_item_ids" => line_item_ids }
        h["destinations"] = destinations.map(&:to_wire_h) unless destinations.empty?
        h["selected_destination_id"] = selected_destination_id if selected_destination_id
        h["groups"] = groups.map(&:to_wire_h) unless groups.empty?
        h
      end
    end

    # schemas/shopping/types/fulfillment_available_method.json — an inventory
    # availability hint (preorder/pickup-today/etc.), independent of whether
    # the buyer has actually chosen that method yet.
    FulfillmentAvailableMethod = Data.define(:type, :line_item_ids, :fulfillable_on, :description) do
      def initialize(type:, line_item_ids:, fulfillable_on: nil, description: nil) = super

      def to_wire_h
        h = { "type" => type, "line_item_ids" => line_item_ids }
        h["fulfillable_on"] = fulfillable_on if fulfillable_on
        h["description"] = description if description
        h
      end
    end

    # schemas/shopping/fulfillment.json#/$defs/dev.ucp.shopping.fulfillment —
    # the Checkout-level container. Named CheckoutFulfillment (not
    # `Fulfillment`, already taken by Order's post-purchase expectations/
    # events container below) to keep the pre-purchase shipping-selection
    # extension and the post-purchase delivery-tracking extension distinct.
    # The member is `shipping_methods`, not the wire key `methods` — a bare
    # `:methods` Data.define member would shadow Kernel#methods.
    CheckoutFulfillment = Data.define(:shipping_methods, :available_methods) do
      def initialize(shipping_methods: [], available_methods: []) = super

      def empty? = shipping_methods.empty? && available_methods.empty?

      def to_wire_h
        h = {}
        h["methods"] = shipping_methods.map(&:to_wire_h) unless shipping_methods.empty?
        h["available_methods"] = available_methods.map(&:to_wire_h) unless available_methods.empty?
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
    # `fulfillment` — the dev.ucp.shopping.fulfillment extension (optional,
    # omitted from the wire payload when empty), same posture as
    # Order#adjustments.
    Checkout = Data.define(:id, :status, :line_items, :currency, :totals, :links, :order, :discounts,
                           :fulfillment) do
      def initialize(id:, status:, line_items:, currency:, totals:, links:, order: nil, discounts: Discounts.new,
                     fulfillment: CheckoutFulfillment.new)
        super
      end

      def to_wire_h
        h = { "id" => id, "status" => status, "line_items" => line_items.map(&:to_wire_h),
              "currency" => currency, "totals" => totals.map(&:to_wire_h), "links" => links.map(&:to_wire_h) }
        h["order"] = order.to_wire_h if order
        h["discounts"] = discounts.to_wire_h unless discounts.empty?
        h["fulfillment"] = fulfillment.to_wire_h unless fulfillment.empty?
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

    # Portage extension (see Adapter#reorder / Capabilities::REORDER) — no
    # schemas/ counterpart to cite, since it isn't part of the UCP spec.
    # `reason` is a short adapter-chosen string (e.g. "out_of_stock",
    # "discontinued"), not a closed enum — same posture as Adapter#cancel_order's
    # `reason:`.
    UnavailableReorderItem = Data.define(:item_id, :title, :reason) do
      def to_wire_h = { "item_id" => item_id, "title" => title, "reason" => reason }
    end

    # Portage extension — the hydrated Cart plus what got dropped along the
    # way, so a caller can tell the buyer what to expect before checkout
    # rather than silently under-filling the cart.
    ReorderResult = Data.define(:cart, :unavailable_items) do
      def initialize(cart:, unavailable_items: []) = super

      def to_wire_h
        h = { "cart" => cart.to_wire_h }
        h["unavailable_items"] = unavailable_items.map(&:to_wire_h) unless unavailable_items.empty?
        h
      end
    end

    Identity = Data.define(:subject, :email, :linked_at)
  end
end

require "portage/ucp"

module Portage
  module Cli
    # The state ConfidenceCheck sends to its model backend, which may be a
    # hosted third-party API (Jev, run by TypeSafe). Built from an allowlist:
    # every field below is copied by name, and nothing else in the checkout
    # hash is ever read. A store can put a buyer block, a shipping address,
    # payment handlers or anything else on its checkout, and none of it
    # reaches the backend, because this never copies a sub-hash wholesale.
    #
    # Never sent: the payment token (or any token reference), the shipping
    # address and destinations, the buyer's name, phone or email, links and
    # continue URLs, ids of the checkout itself, image URLs, discount codes,
    # and anything read from the environment.
    #
    # Sent:
    # - `request`: the search query, the store's host, the requested
    #   quantity, and the item id and title that were picked from the
    #   store's own search results.
    # - `approved_quote` (only on `buy --quote`): the store, product id,
    #   title, quantity, total and currency the person approved.
    # - `checkout`: its status and currency; each line's item id, title,
    #   unit price, quantity, line totals and whether it is the requested
    #   line; the checkout's totals (subtotal, shipping, tax, fees, total:
    #   whatever types the store sends); applied discounts' titles and
    #   amounts; and the title and price of each selected shipping option.
    # - `warnings`: the deterministic check's warnings, if any.
    #
    # Strings are cut to MAX_STRING characters and anything that isn't a
    # string, number, boolean or nil is dropped, so a store can't smuggle a
    # nested object (or a very long prompt) in through a title.
    module ConfidenceState
      MAX_STRING = 200

      module_function

      # @param request [Hash] `query:`, `merchant:`, `quantity:`,
      #   `item_id:`, `item_title:`.
      # @param checkout [Hash] a checkout or cart wire hash, string-keyed.
      # @param warnings [Array<String>]
      # @param quote [Hash, nil] `store:`, `product_id:`, `title:`,
      #   `quantity:`, `total:`, `currency:` — nil when the run has no
      #   approved quote.
      # @return [Hash] JSON-serializable, string-keyed.
      def build(request:, checkout:, warnings:, quote: nil)
        state = { "request" => pick(request, %i[query merchant quantity item_id item_title]) }
        state["approved_quote"] = pick(quote, %i[store product_id title quantity total currency]) if quote
        state["checkout"] = checkout_summary(checkout, request[:item_id])
        state["warnings"] = Array(warnings).map { |warning| scalar(warning.to_s) }
        state
      end

      def checkout_summary(checkout, requested_id)
        { "status" => scalar(checkout["status"]), "currency" => scalar(checkout["currency"]),
          "line_items" => Array(checkout["line_items"]).map { |line| line_summary(line, requested_id) },
          "totals" => totals_summary(checkout["totals"]),
          "discounts" => discounts_summary(checkout["discounts"]),
          "shipping" => shipping_summary(checkout["fulfillment"]) }
      end

      def line_summary(line, requested_id)
        line = {} unless line.is_a?(Hash)
        item = line["item"].is_a?(Hash) ? line["item"] : {}
        { "item_id" => scalar(item["id"]), "title" => scalar(item["title"]), "unit_price" => scalar(item["price"]),
          "quantity" => scalar(line["quantity"]), "totals" => totals_summary(line["totals"]),
          "requested" => !requested_id.nil? && item["id"] == requested_id }
      end

      def totals_summary(totals)
        hashes(totals).map { |total| { "type" => scalar(total["type"]), "amount" => scalar(total["amount"]) } }
      end

      def discounts_summary(discounts)
        applied = discounts.is_a?(Hash) ? discounts["applied"] : nil
        hashes(applied).map do |discount|
          { "title" => scalar(discount["title"]), "amount" => scalar(discount["amount"]) }
        end
      end

      # Only the options the checkout has selected — the price the person
      # pays for shipping — never the destinations they're priced for.
      def shipping_summary(fulfillment)
        methods = fulfillment.is_a?(Hash) ? fulfillment["methods"] : nil
        hashes(methods).flat_map { |method| hashes(method["groups"]) }.filter_map do |group|
          option = hashes(group["options"]).find { |o| o["id"] == group["selected_option_id"] }
          next unless option

          { "title" => scalar(option["title"]),
            "amount" => scalar(Portage::Ucp::Support::Totals.amount(hashes(option["totals"]))) }
        end
      end

      def pick(hash, keys)
        keys.to_h { |key| [key.to_s, scalar(hash[key])] }
      end

      def hashes(value) = Array(value).grep(Hash)

      def scalar(value)
        case value
        when String then value[0, MAX_STRING]
        when Integer, true, false, nil then value
        when Float then value.finite? ? value : nil
        end
      end
    end
  end
end

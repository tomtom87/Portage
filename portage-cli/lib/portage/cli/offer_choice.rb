require_relative "product_page"
require_relative "money"

module Portage
  module Cli
    # One offer as a render-ready choice (docs/plans/human-pick-and-approve.md
    # Phase 2): what `portage pick` returns in `needs_pick`'s `choices[]`,
    # and what HumanPrompt#choose lists for `pick` and `buy --query` alike.
    # `url` is the product page as find/compare returned it; the agent shows
    # it as a link next to the choice.
    module OfferChoice
      module_function

      # @param offer [Hash] a find report's symbol-keyed offer or a saved
      #   (History) string-keyed one.
      def for(offer)
        offer = offer.transform_keys(&:to_s)
        { ref: offer["offer_ref"], label: label(offer), store: offer["store"], product_id: offer["product_id"],
          title: offer["title"], amount: offer["amount"], currency: offer["currency"],
          checkout: offer["checkout"], url: offer["url"] }
      end

      def label(offer)
        price = offer["amount"] ? Money.format_amount(offer["amount"], offer["currency"]) : "price n/a"
        parts = [offer["store"], offer["title"], price]
        parts << "browse only" if offer["checkout"] == false
        parts.compact.join(" — ")
      end

      # The tty `v N` answer for one choice: the page's own outcome message.
      def view_message(choice)
        return "Nothing to view for that choice." unless choice[:store]

        ProductPage.new(url: choice[:url], store: choice[:store]).open[:message]
      end
    end
  end
end

module Portage
  module Ucp
    module Support
      # The offer-ranking rule (docs/plans/system-one-decision-layer.md
      # § Responsibilities 1), held in core the way PolicyGuard holds the
      # policy rule. portage-ucp-decision's OfferRanking is a typed wrapper
      # around it, and portage-cli calls it directly, so `portage find`
      # ranks the same way whether or not that gem is installed.
      #
      # Buyable first, then priced, then cheapest, with ties kept in input
      # order. Sorting on price alone would float a browse-only offer above
      # one you can actually check out from.
      module OfferRanking
        module_function

        # @param offers [Array] in whatever shape the caller holds them.
        # @yieldparam offer one element of `offers`.
        # @yieldreturn [Array(Boolean, Integer)] whether the offer can be
        #   checked out, and its minor-unit amount (nil when unpriced).
        # @return [Array] the same offers, ranked.
        def rank(offers)
          offers.sort_by.with_index do |offer, index|
            buyable, amount = yield(offer)
            [buyable ? 0 : 1, amount ? 0 : 1, amount || 0, index]
          end
        end
      end
    end
  end
end

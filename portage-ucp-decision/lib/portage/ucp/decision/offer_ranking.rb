module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 1.
      #
      # Generalizes the ranking `portage find` already does inline
      # (portage-cli/lib/portage/cli/find.rb#rank) into a reusable typed
      # decision: buyable candidates first, then cheapest, then unpriced —
      # sorting on price alone would float a browse-only offer above one you
      # can actually check out from.
      module OfferRanking
        # A caller's candidate, wrapped just enough for ranking to compare
        # it — the caller keeps whatever richer type (Product, a CLI hash,
        # an agent-loop's own struct) it already has on `#offer`.
        Candidate = Data.define(:offer, :buyable, :amount)

        # @param candidates [Array<Candidate>]
        # @return [Array<Candidate>] the same candidates, stable-sorted
        #   buyable-first, cheapest-first, unpriced-last.
        def self.call(candidates)
          candidates.sort_by.with_index do |candidate, index|
            [candidate.buyable ? 0 : 1, candidate.amount ? 0 : 1, candidate.amount || 0, index]
          end
        end
      end
    end
  end
end

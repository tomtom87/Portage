require "portage/ucp"

module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 1.
      #
      # A typed wrapper around `Portage::Ucp::Support::OfferRanking`, the
      # way PolicyCheck wraps `PolicyGuard`. The rule itself lives in core:
      # buyable candidates first, then cheapest, then unpriced. portage-cli
      # calls core directly, so its ranking can't drift from this one.
      module OfferRanking
        # A caller's candidate, wrapped just enough for ranking to compare
        # it — the caller keeps whatever richer type (Product, a CLI hash,
        # an agent-loop's own struct) it already has on `#offer`.
        Candidate = Data.define(:offer, :buyable, :amount)

        # @param candidates [Array<Candidate>]
        # @return [Array<Candidate>] the same candidates, stable-sorted
        #   buyable-first, cheapest-first, unpriced-last.
        def self.call(candidates)
          Portage::Ucp::Support::OfferRanking.rank(candidates) { |candidate| [candidate.buyable, candidate.amount] }
        end
      end
    end
  end
end

require "digest"

module Portage
  module Ucp
    module Support
      # One-way, non-reversible reference to a payment token, shared by
      # Dispatcher (transaction log rows) and portage-cli's PaymentMethods
      # (per-token policy scopes, docs/plans/agentic-payments.md Phase 2) so
      # both sides derive the same id from the same token without either one
      # persisting the token itself.
      module TokenRef
        def self.for(token)
          return nil if token.nil?

          Digest::SHA256.hexdigest(token.to_s)[0, 16]
        end
      end
    end
  end
end

module Portage
  module Ucp
    module Support
      class TransactionLog
        # @abstract Pluggable persistence for TransactionLog — same
        #   "no bundled storage assumption" posture as
        #   Portage::Ucp::Journal::Store (design-log §22, §33). The
        #   interface sits at the semantic level TransactionLog itself
        #   exposes (reserve/complete/record_decision/record_confirmation/
        #   find/completed_since), not a bare key-value split: spend-cap and
        #   velocity queries need shop+status+time filtering
        #   (`completed_since`) that a generic fetch/store can't do.
        #
        #   A Store operates on plain record hashes already built by
        #   TransactionLog and does not raise the semantic errors
        #   (`ArgumentError` on bad status, `KeyError` on an unreserved
        #   key) — those are TransactionLog's contract, not storage's.
        #   `#complete`/`#record_decision`/`#record_confirmation` return
        #   `nil` when no record was reserved for the key, and
        #   TransactionLog turns that into `KeyError`.
        class Store
          # Persists `record` (already built by TransactionLog, keyed by
          # `record["idempotency_key"]`) and returns it.
          def reserve(record)
            raise NotImplementedError, "#{self.class} must implement #reserve"
          end

          # Applies `updates` to the previously reserved record for
          # `idempotency_key` and returns the updated record, or `nil` if
          # no record was ever reserved for that key.
          def complete(idempotency_key, updates)
            raise NotImplementedError, "#{self.class} must implement #complete"
          end

          def record_decision(idempotency_key, policy_decision)
            raise NotImplementedError, "#{self.class} must implement #record_decision"
          end

          def record_confirmation(idempotency_key, confirmation_outcome)
            raise NotImplementedError, "#{self.class} must implement #record_confirmation"
          end

          def find(idempotency_key)
            raise NotImplementedError, "#{self.class} must implement #find"
          end

          def completed_since(since, shop:)
            raise NotImplementedError, "#{self.class} must implement #completed_since"
          end
        end
      end
    end
  end
end

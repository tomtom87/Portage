module Portage
  module Ucp
    module Support
      class OrderLedger
        # @abstract Pluggable persistence for OrderLedger — mirrors
        #   `TransactionLog::Store` (design-log §33). Operates on plain
        #   record hashes already built by OrderLedger; raises no semantic
        #   errors of its own (OrderLedger has none today — every `record`
        #   overwrites unconditionally).
        class Store
          # Persists `record` keyed by `order_id` and returns it.
          def record(order_id, record)
            raise NotImplementedError, "#{self.class} must implement #record"
          end

          def find(order_id)
            raise NotImplementedError, "#{self.class} must implement #find"
          end

          # Yields every snapshot, in no guaranteed order, without a block
          # returns an Enumerator — same §22 item 6 console read surface
          # added to `TransactionLog::Store`. Additive; `#find` is unchanged.
          def each_record(&)
            raise NotImplementedError, "#{self.class} must implement #each_record"
          end
        end
      end
    end
  end
end

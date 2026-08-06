module Portage
  module Ucp
    module Support
      # §9a: mutating Adapter methods must dedup by idempotency_key so an
      # agent's retry on a dropped connection can't double-charge. None of
      # the commerce APIs behind the bundled adapter gems takes an
      # idempotency key natively (Shopify's cartSubmitForCompletion attemptId
      # is the one partial exception), so every adapter keeps an in-process
      # dedup table — this is that table.
      #
      # In-process only: a multi-process deployment that must dedup across
      # workers needs a shared store, which is a consumer concern the same
      # way RateLimiter is.
      module Idempotency
        private

        def dedup(idempotency_key)
          @idempotency_results ||= {}
          return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

          @idempotency_results[idempotency_key] = yield
        end
      end
    end
  end
end

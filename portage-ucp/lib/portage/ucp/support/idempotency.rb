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
        # Guards lazy init of each instance's lock table below — brief and
        # only touched once per instance, not on the hot dedup path.
        INIT_MUTEX = Mutex.new

        private

        def dedup(idempotency_key)
          init_idempotency_locks!

          key_lock = @idempotency_mutex.synchronize { @idempotency_locks[idempotency_key] ||= Mutex.new }

          key_lock.synchronize do
            return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

            @idempotency_results[idempotency_key] = yield
          end
        end

        def init_idempotency_locks!
          return if @idempotency_mutex

          INIT_MUTEX.synchronize do
            @idempotency_mutex ||= Mutex.new
            @idempotency_results ||= {}
            @idempotency_locks ||= {}
          end
        end
      end
    end
  end
end

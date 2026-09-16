module Portage
  module Ucp
    module Support
      # §21: multi-call mutations (read-modify-write against Shopify's
      # Storefront API, or the equivalent REST sequence on Wix) aren't
      # atomic upstream, so two concurrent calls against the same cart or
      # checkout id can interleave and drop each other's writes — not just
      # a lost update, lines vanish. This serializes calls per id so a
      # concurrent duplicate waits for the first to finish instead of
      # racing it.
      #
      # In-process only, same caveat as RateLimiter and Idempotency: a
      # multi-process deployment needs a shared lock, which is a consumer
      # concern. Keep #synchronize as the only method a consumer touches so
      # a Redis-backed replacement can drop in without adapters changing.
      module SessionLock
        INIT_MUTEX = Mutex.new

        private

        def synchronize(session_id, &)
          init_session_locks!

          key_lock = checkout_session_lock(session_id)
          begin
            key_lock.synchronize(&)
          ensure
            checkin_session_lock(session_id)
          end
        end

        def init_session_locks!
          return if @session_lock_mutex

          INIT_MUTEX.synchronize do
            @session_lock_mutex ||= Mutex.new
            @session_locks ||= {}
          end
        end

        # Same unbounded-growth problem as Idempotency's per-key locks: one
        # Mutex per session/cart id, never removed, in a process that outlives
        # any single session. Refcount instead of `Mutex#locked?` so an entry
        # is only reaped once no thread — including one still queued on
        # `key_lock.synchronize` — holds a reference to it; deleting on
        # `locked?` alone would let a queued waiter end up serialized against
        # a disconnected Mutex a new caller replaced it with.
        def checkout_session_lock(session_id)
          @session_lock_mutex.synchronize do
            entry = (@session_locks[session_id] ||= { mutex: Mutex.new, refcount: 0 })
            entry[:refcount] += 1
            entry[:mutex]
          end
        end

        def checkin_session_lock(session_id)
          @session_lock_mutex.synchronize do
            entry = @session_locks[session_id]
            entry[:refcount] -= 1
            @session_locks.delete(session_id) if entry[:refcount].zero?
          end
        end
      end
    end
  end
end

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

        def synchronize(session_id)
          init_session_locks!

          key_lock = @session_lock_mutex.synchronize { @session_locks[session_id] ||= Mutex.new }

          key_lock.synchronize { yield }
        end

        def init_session_locks!
          return if @session_lock_mutex

          INIT_MUTEX.synchronize do
            @session_lock_mutex ||= Mutex.new
            @session_locks ||= {}
          end
        end
      end
    end
  end
end

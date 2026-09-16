module Portage
  module Ucp
    module Support
      # §9a: mutating Adapter methods must dedup by idempotency_key so an
      # agent's retry on a dropped connection can't double-charge. None of
      # the commerce APIs behind the bundled adapter gems takes an
      # idempotency key natively (Shopify's cartSubmitForCompletion attemptId
      # is the one partial exception), so every adapter keeps a dedup table
      # — this is that table, now backed by a pluggable store instead of a
      # bare Hash.
      #
      # Defaults to a fresh `MemoryStore` per including instance (in-process,
      # lost on restart — the same durability the old bare Hash had, and
      # the same isolation: one adapter instance's dedup table never leaks
      # into another's). A consumer that needs dedup to survive a process
      # restart or be shared across processes (the actual complaint behind
      # this: a single-host CLI invoked fresh per command, or a
      # multi-worker server) sets `Portage::Ucp.configuration.idempotency_provider`
      # once via `configure { |c| c.idempotency_provider = ... }` — every
      # instance that doesn't set its own store via `idempotency_store=`
      # then shares that one process-wide store instead of each getting its
      # own in-memory table. `FileStore` ships for the single-host case;
      # Redis/SQLite-backed stores are a consumer's own implementation
      # against the same two-method interface (`#fetch(key)` /
      # `#store(key, value)`).
      module Idempotency
        # Sentinel distinguishing "no entry" from a memoized `nil` result.
        NOT_FOUND = Object.new.freeze

        # Guards lazy init of each instance's lock table below — brief and
        # only touched once per instance, not on the hot dedup path.
        INIT_MUTEX = Mutex.new

        # Injects a store other than the default `MemoryStore` — call this
        # before the first `dedup`, typically from the including class's
        # `initialize`. Public because store choice is a deployment concern
        # (which durability a consumer needs), unlike `dedup` itself, which
        # stays private/adapter-internal.
        def idempotency_store=(store)
          @idempotency_store = store
        end

        private

        def dedup(idempotency_key, &block)
          init_idempotency_locks!

          key_lock = @idempotency_mutex.synchronize { @idempotency_locks[idempotency_key] ||= Mutex.new }

          # `key_lock` only serializes threads inside *this* process — it can't
          # stop a second `portage` invocation (a second process, its own
          # Mutex) from racing this one. That's the store's job: `fetch` then
          # `store` as two separate calls (the old shape here) is two separate
          # lock acquisitions on `FileStore`, so both processes can observe
          # NOT_FOUND and both run `yield` — the double-charge §9a exists to
          # prevent. `fetch_or_store` does the whole check-then-set under one
          # lock acquisition instead.
          key_lock.synchronize { idempotency_store.fetch_or_store(idempotency_key, &block) }
        end

        def idempotency_store
          @idempotency_store ||= Portage::Ucp.configuration.idempotency_provider || MemoryStore.new
        end

        def init_idempotency_locks!
          return if @idempotency_mutex

          INIT_MUTEX.synchronize do
            @idempotency_mutex ||= Mutex.new
            @idempotency_locks ||= {}
          end
        end
      end
    end
  end
end

require_relative "idempotency/memory_store"
require_relative "idempotency/file_store"

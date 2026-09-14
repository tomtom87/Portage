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
      # Defaults to `MemoryStore` (in-process, lost on restart — the same
      # durability the old bare Hash had). A consumer that needs dedup to
      # survive a process restart or be shared across processes (the actual
      # complaint behind this: a single-host CLI invoked fresh per command,
      # or a multi-worker server) injects a different store via
      # `idempotency_store=` — `FileStore` ships for the single-host case;
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

        def dedup(idempotency_key)
          init_idempotency_locks!

          key_lock = @idempotency_mutex.synchronize { @idempotency_locks[idempotency_key] ||= Mutex.new }

          key_lock.synchronize do
            cached = idempotency_store.fetch(idempotency_key)
            next cached unless cached.equal?(NOT_FOUND)

            idempotency_store.store(idempotency_key, yield)
          end
        end

        def idempotency_store
          @idempotency_store ||= MemoryStore.new
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

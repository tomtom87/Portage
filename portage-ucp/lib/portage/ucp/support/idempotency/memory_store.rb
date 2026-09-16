module Portage
  module Ucp
    module Support
      module Idempotency
        # Default store: an in-process Hash. Same durability as the table
        # this replaced — lost on restart, not shared across processes — kept
        # as the default because it's still correct for the common case
        # (single adapter instance, one process, one request at a time isn't
        # guaranteed but per-key locking in `Idempotency#dedup` covers that).
        class MemoryStore
          def initialize
            @data = {}
            @mutex = Mutex.new
          end

          def fetch(key)
            @mutex.synchronize { @data.key?(key) ? @data[key] : NOT_FOUND }
          end

          def store(key, value)
            @mutex.synchronize { @data[key] = value }
          end

          # Atomic check-then-set: `Idempotency#dedup`'s own per-key `Mutex`
          # already serializes same-process racers on this key, so a plain
          # fetch-then-store pair is safe here — unlike `FileStore`, there's
          # no second process able to interleave between the two steps.
          def fetch_or_store(key)
            cached = fetch(key)
            return cached unless cached.equal?(NOT_FOUND)

            store(key, yield)
          end

          # Duck-types Hash#include? so this can stand in wherever a caller
          # (e.g. the conformance kit, `rspec.rb`) just wants to assert a key
          # was dedup'd, without reaching for the internal `fetch` sentinel.
          def include?(key)
            @mutex.synchronize { @data.key?(key) }
          end
        end
      end
    end
  end
end

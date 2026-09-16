require "fileutils"

module Portage
  module Ucp
    module Support
      module Idempotency
        # Cross-process, cross-restart store for the common CLI case: one
        # host, potentially many `portage` invocations, no shared server to
        # hold an in-memory table for them. A dedicated `.lock` file under
        # `flock` stands in for that — see `with_lock` for why it's a
        # separate file from the data file. `#fetch`/`#store` each acquire
        # the lock for their own call only, so pairing them (the old
        # `Idempotency#dedup` shape) leaves a window between the two
        # acquisitions where a second process can also read NOT_FOUND and
        # also run the mutation — dedup now goes through `#fetch_or_store`
        # instead, which holds one lock across the whole check-then-set and
        # is what actually gives two processes racing on the same key the
        # guarantee that only one of them runs it.
        #
        # Marshal, not JSON: dedup'd return values are arbitrary adapter
        # domain objects (Data.define value objects, nested structures) that
        # JSON can't round-trip losslessly. This is safe only because the
        # file is written and read by this same trusted local process/user —
        # the same trust boundary the CLI process already sits inside (see
        # docs/plans/agentic-payments.md's "local policy guards agent
        # mistakes, not a compromised agent").
        #
        # Not injected as the default (`MemoryStore` is) — a consumer that
        # wants durability across processes constructs one explicitly and
        # passes it wherever it builds its adapter/Dispatcher.
        class FileStore
          def initialize(path: File.join(Dir.home, ".portage", "idempotency.marshal"))
            @path = path
            @lock_path = "#{path}.lock"
          end

          def fetch(key)
            with_lock(File::LOCK_SH) { |data| data.key?(key) ? data[key] : NOT_FOUND }
          end

          def store(key, value)
            with_lock(File::LOCK_EX) do |data|
              data[key] = value
              persist(data)
            end
            value
          end

          def include?(key)
            with_lock(File::LOCK_SH) { |data| data.key?(key) }
          end

          # Atomic check-then-set, unlike calling `fetch` then `store`: those
          # are two separate `with_lock` acquisitions, so the shared lock is
          # released between them and a second process can read NOT_FOUND in
          # the gap and run the same mutation — the exact double-charge §9a
          # exists to prevent. Holding one `LOCK_EX` across the read, the
          # block (the actual mutation), and the write closes that window.
          # Coarser-grained than a per-key lock — this blocks *every* key on
          # the file while one mutation is in flight, not just this one — but
          # correctness beats throughput for a single-host CLI process, and
          # that's the case this store is documented for.
          def fetch_or_store(key)
            with_lock(File::LOCK_EX) do |data|
              next data[key] if data.key?(key)

              value = yield
              data[key] = value
              persist(data)
              value
            end
          end

          private

          # Locks a sidecar `.lock` file rather than `@path` itself, because
          # `persist` below replaces `@path` via rename to avoid ever leaving
          # a torn write on disk. A lock held on the data file's inode
          # wouldn't survive that swap — a second process already blocked on
          # `flock` for the old inode would wake up into a stale, pre-write
          # view instead of being serialized after the write. The lock file
          # is never renamed, so it stays a stable thing to serialize on.
          def with_lock(lock_mode)
            FileUtils.mkdir_p(File.dirname(@path))
            File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock_file|
              lock_file.flock(lock_mode)
              yield(read)
            end
          end

          def read
            return {} unless File.exist?(@path)

            raw = File.read(@path)
            return {} if raw.empty?

            # rubocop:disable Security/MarshalLoad -- this file is written only
            # by this same trusted local process/user (chmod 0600, no network
            # exposure); see the class comment on the trust boundary.
            Marshal.load(raw)
            # rubocop:enable Security/MarshalLoad
          rescue StandardError
            # A truncated write (crash mid-persist) or a renamed/removed class
            # (Marshal replays the dumped class name) both poison this file
            # forever without a rescue here — every future `portage`
            # invocation would raise just from opening the store. Treat
            # either as an empty store, same posture as OrderLedger::FileStore
            # rescuing JSON::ParserError.
            {}
          end

          def persist(data)
            tmp_path = "#{@path}.#{Process.pid}.#{object_id}.tmp"
            File.open(tmp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |tmp|
              tmp.write(Marshal.dump(data))
              tmp.flush
            end
            # Rename, not truncate+write in place: a crash between truncate
            # and write used to leave a half-written file that `read` above
            # would then have to poison-recover from. A rename is atomic, so
            # readers only ever see the old complete file or the new complete
            # one, never a torn one.
            File.rename(tmp_path, @path)
            File.chmod(0o600, @path)
          end
        end
      end
    end
  end
end

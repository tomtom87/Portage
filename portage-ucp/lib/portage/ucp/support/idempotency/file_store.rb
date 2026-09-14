require "fileutils"

module Portage
  module Ucp
    module Support
      module Idempotency
        # Cross-process, cross-restart store for the common CLI case: one
        # host, potentially many `portage` invocations, no shared server to
        # hold an in-memory table for them. A single file under `flock`
        # stands in for that — every read/write acquires the lock so two
        # processes racing on the same key don't both run the mutation.
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
          end

          def fetch(key)
            with_lock(File::LOCK_SH) { |data, _file| data.key?(key) ? data[key] : NOT_FOUND }
          end

          def store(key, value)
            with_lock(File::LOCK_EX) do |data, file|
              data[key] = value
              persist(data, file)
            end
            value
          end

          def include?(key)
            with_lock(File::LOCK_SH) { |data, _file| data.key?(key) }
          end

          private

          def with_lock(lock_mode)
            FileUtils.mkdir_p(File.dirname(@path))
            File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
              file.flock(lock_mode)
              yield(read(file), file)
            end
          end

          def read(file)
            file.rewind
            raw = file.read
            return {} if raw.empty?

            # rubocop:disable Security/MarshalLoad -- this file is written only
            # by this same trusted local process/user (chmod 0600, no network
            # exposure); see the class comment on the trust boundary.
            Marshal.load(raw)
            # rubocop:enable Security/MarshalLoad
          end

          def persist(data, file)
            file.rewind
            file.truncate(0)
            file.write(Marshal.dump(data))
            file.flush
            File.chmod(0o600, @path)
          end
        end
      end
    end
  end
end

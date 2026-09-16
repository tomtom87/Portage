require "json"
require "fileutils"

module Portage
  module Ucp
    module Support
      class OrderLedger
        # Default Store: the whole-file `flock` + chmod 0600 + JSON
        # read/persist mechanics that used to live directly on OrderLedger
        # (extracted verbatim from `order_ledger.rb` pre-Store) — no
        # behavior change, just a seam.
        #
        # Same raising-write posture as OrderLedger itself — see that
        # class's comment. No `rescue StandardError; nil` here.
        class FileStore < Store
          PATH = File.join(Dir.home, ".portage", "orders.json").freeze

          def initialize(path: PATH)
            super()
            @path = path
          end

          def record(order_id, record)
            with_lock(File::LOCK_EX) do |data, file|
              data[order_id] = record
              persist(data, file)
            end
            record
          end

          def find(order_id)
            with_lock(File::LOCK_SH) { |data, _file| data[order_id] }
          end

          def each_record(&block)
            return enum_for(:each_record) unless block

            with_lock(File::LOCK_SH) { |data, _file| data.values }.each(&block)
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

            parsed = JSON.parse(raw)
            parsed.is_a?(Hash) ? parsed : {}
          rescue JSON::ParserError
            {}
          end

          # No `rescue StandardError; nil` — see class comment. A failed
          # write here must raise, not vanish.
          def persist(data, file)
            file.rewind
            file.truncate(0)
            file.write(JSON.pretty_generate(data))
            file.flush
            File.chmod(0o600, @path)
          end
        end
      end
    end
  end
end

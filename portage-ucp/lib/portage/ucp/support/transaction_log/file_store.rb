require "json"
require "fileutils"
require "time"

module Portage
  module Ucp
    module Support
      class TransactionLog
        # Default Store: the whole-file `flock` + chmod 0600 + JSON
        # read/persist mechanics that used to live directly on
        # TransactionLog (extracted verbatim from `transaction_log.rb`
        # pre-Store) — no behavior change, just a seam.
        #
        # Same raising-write posture as TransactionLog itself — see that
        # class's comment. No `rescue StandardError; nil` here.
        class FileStore < Store
          PATH = File.join(Dir.home, ".portage", "transactions.json").freeze

          def initialize(path: PATH)
            super()
            @path = path
          end

          def reserve(record)
            with_lock(File::LOCK_EX) do |data, file|
              data[record["idempotency_key"]] = record
              persist(data, file)
            end
            record
          end

          def complete(idempotency_key, updates)
            with_lock(File::LOCK_EX) do |data, file|
              record = data[idempotency_key]
              next nil unless record

              record.merge!(updates)
              persist(data, file)
              record
            end
          end

          def record_decision(idempotency_key, policy_decision)
            with_lock(File::LOCK_EX) do |data, file|
              record = data[idempotency_key]
              next nil unless record

              record["policy_decision"] = policy_decision
              persist(data, file)
              record
            end
          end

          def record_confirmation(idempotency_key, confirmation_outcome)
            with_lock(File::LOCK_EX) do |data, file|
              record = data[idempotency_key]
              next nil unless record

              record["confirmation_outcome"] = confirmation_outcome
              persist(data, file)
              record
            end
          end

          def find(idempotency_key)
            with_lock(File::LOCK_SH) { |data, _file| data[idempotency_key] }
          end

          def completed_since(since, shop:)
            with_lock(File::LOCK_SH) do |data, _file|
              data.values.select do |record|
                record["status"] == "complete" && record["shop"] == shop && record["completed_at"] &&
                  Time.parse(record["completed_at"]) >= since
              end
            end
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

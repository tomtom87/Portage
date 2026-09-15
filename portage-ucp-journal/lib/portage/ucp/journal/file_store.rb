require "json"
require "fileutils"

module Portage
  module Ucp
    module Journal
      # Default Store: a JSON-Lines file, one record per line. Genuinely
      # append-only — unlike core's TransactionLog/OrderLedger, #append never
      # reads or rewrites the whole file, so a large journal stays cheap to
      # write to and a crash mid-append can only ever lose the one
      # in-flight line, never corrupt an earlier one.
      #
      # Same raising-write posture as TransactionLog/OrderLedger: a lost
      # write here is a silent hole in the buyer's own purchase record, so
      # there is no `rescue StandardError; nil` anywhere in this class.
      class FileStore < Store
        PATH = File.join(Dir.home, ".portage", "journal.jsonl").freeze

        def initialize(path: PATH)
          super()
          @path = path
        end

        def append(record)
          FileUtils.mkdir_p(File.dirname(@path))
          File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
            file.flock(File::LOCK_EX)
            file.write("#{JSON.generate(record)}\n")
            file.flush
          end
          record
        end

        # Skips a torn trailing line (a crash mid-write leaves at most one
        # unparseable final line) rather than raising — every earlier,
        # complete line is still good and must not be lost because the last
        # one wasn't. A torn line in the *middle* of the file would indicate
        # something worse than a crash mid-append (the file was hand-edited,
        # or two writers bypassed the flock) and is left to surface as a
        # JSON::ParserError rather than silently swallowed anywhere but the
        # last line.
        def each_record
          return enum_for(:each_record) unless block_given?

          return unless File.exist?(@path)

          lines = File.open(@path, File::RDONLY) do |file|
            file.flock(File::LOCK_SH)
            file.readlines
          end

          lines.each_with_index do |line, index|
            yield JSON.parse(line)
          rescue JSON::ParserError
            raise unless index == lines.length - 1
          end
        end
      end
    end
  end
end

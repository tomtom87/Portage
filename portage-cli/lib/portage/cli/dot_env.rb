require "fileutils"

module Portage
  module Cli
    # Loads `~/.portage/.env` (or the file PORTAGE_ENV_FILE names) into ENV
    # before `portage`/`portage-console` run, so shipping address, search
    # keys and adapter credentials can live in one file next to config.json
    # instead of a shell profile. A Homebrew install has no repo checkout to
    # keep a `.env` in, so the user's own Portage directory is the one place
    # every install method shares.
    #
    # Deliberately *not* `./.env` from the working directory: `portage` run
    # inside a cloned repo would then take that repo's PORTAGE_PROXY/
    # PORTAGE_PROXY_CA (an intercepting proxy on store traffic), notify
    # webhooks or store credentials without the user ever choosing them.
    # PORTAGE_ENV_FILE=.env opts into a project file explicitly.
    #
    # Stdlib only (no dotenv gem, so the formula gains no resource). The real
    # environment always wins, and an empty value is skipped, so a file
    # copied from .env.example with blanks left in sets nothing.
    module DotEnv
      DEFAULT_PATH = File.join(Dir.home, ".portage", ".env").freeze
      ESCAPES = { "n" => "\n", '"' => '"', "\\" => "\\" }.freeze
      LINE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/

      class << self
        # The file #load read in this process, for `portage doctor`.
        attr_reader :loaded_path
      end

      # @return [String, nil] the path that was loaded, if any.
      def self.load(path: ENV.fetch("PORTAGE_ENV_FILE", nil) || DEFAULT_PATH, env: ENV)
        path = File.expand_path(path)
        return unless File.file?(path) && File.readable?(path)

        parse(File.read(path)).each { |key, value| env[key] = value unless env.key?(key) }
        @loaded_path = path
      end

      # @return [Hash{String => String}] non-empty assignments, in file order.
      def self.parse(text)
        text.each_line.filter_map do |line|
          match = LINE.match(line.chomp)
          next unless match

          value = unquote(match[2])
          [match[1], value] unless value.empty?
        end.to_h
      end

      # `"..."` (with \n, \" and \\ escapes) or `'...'` (literal); unquoted
      # values drop a trailing ` # comment`.
      def self.unquote(raw)
        case raw
        when /\A"((?:[^"\\]|\\.)*)"/
          Regexp.last_match(1).gsub(/\\([n"\\])/) { ESCAPES.fetch(Regexp.last_match(1)) }
        when /\A'([^']*)'/ then Regexp.last_match(1)
        else raw.sub(/\s+#.*\z/, "").strip
        end
      end
      private_class_method :unquote

      # Writes `assignments` into the `.env` file at `path` (creating
      # `~/.portage` if needed), for `portage setup`'s wizard
      # (docs/plans/buy-skill-and-local-browser.md Phase 4) — the only
      # writer this file has had until now. A key already on a line is
      # replaced in place, so a re-run never duplicates it and every other
      # line (unrelated keys, comments, blank lines) is left exactly as it
      # was; a key that isn't already there is appended. `assignments`
      # values are always double-quoted on write (never bare) so a value
      # with a space — a street address — round-trips through #parse
      # correctly.
      #
      # Mode 0600 from the very first byte, whether or not the file existed
      # before: an existing file is chmod'd 600 *before* anything is
      # written into it (an existing file could already be world-readable),
      # and a new file is opened with mode 0600 baked into its `File.open`
      # call — never `File.write` then `File.chmod`, which briefly leaves a
      # brand-new file (holding a shipping address or a search API key) at
      # the process umask's permissions, e.g. 0644, before the chmod lands.
      #
      # @param assignments [Hash{String => String}]
      # @return [String] the path written.
      def self.update!(assignments, path: ENV.fetch("PORTAGE_ENV_FILE", nil) || DEFAULT_PATH)
        path = File.expand_path(path)
        remaining = assignments.dup
        lines = existing_lines(path).map { |line| replace_assignment(line, remaining) }
        remaining.each { |key, value| lines << assignment_line(key, value) }

        FileUtils.mkdir_p(File.dirname(path))
        File.chmod(0o600, path) if File.file?(path)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(lines.join) }
        File.chmod(0o600, path)
        path
      end

      def self.existing_lines(path)
        File.file?(path) ? File.readlines(path) : []
      end
      private_class_method :existing_lines

      def self.replace_assignment(line, remaining)
        match = LINE.match(line.chomp)
        return line unless match && remaining.key?(match[1])

        assignment_line(match[1], remaining.delete(match[1]))
      end
      private_class_method :replace_assignment

      def self.assignment_line(key, value)
        escaped = value.to_s.gsub("\\") { "\\\\" }.gsub('"') { "\\\"" }
        "#{key}=\"#{escaped}\"\n"
      end
      private_class_method :assignment_line
    end
  end
end

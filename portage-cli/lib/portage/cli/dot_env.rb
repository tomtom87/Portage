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
    end
  end
end

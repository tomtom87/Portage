require_relative "sqlite"

module Portage
  module Cli
    module BrowserImport
      # Where each supported browser keeps its profiles, and the exact
      # files `portage browser import` is allowed to read from one.
      #
      # ALLOWED_FILES is the whole list — History/Bookmarks for the
      # Chromium family, places.sqlite for Firefox, History.db/
      # Bookmarks.plist for Safari. Nothing else in a profile directory is
      # ever opened, copied or listed: not `Login Data`, `Cookies`,
      # `Web Data` (autofill), `logins.json`, `key4.db`, `cookies.sqlite`,
      # `formhistory.sqlite`, nor the keychain (docs/plans/
      # buy-skill-and-local-browser.md, "Never, in any tier"; profiles_spec/
      # importer_spec assert this against a fixture profile full of decoys).
      # (Sqlite also copies an allowed database's own `-wal` file when one
      # exists — it's part of that same database, holding its newest rows.)
      # A profile's own *directory* is only ever stat'ed for these names,
      # never listed; the one directory listing this does is the profile
      # *root* (which profile folders exist — `Default`, `Profile 1`, …),
      # never a profile's own contents.
      module Profiles
        Profile = Struct.new(:browser, :family, :dir, :history, :bookmarks, keyword_init: true)

        CHROMIUM = %w[chrome edge brave arc].freeze

        ALLOWED_FILES = {
          "chromium" => { history: "History", bookmarks: "Bookmarks" },
          "firefox" => { history: "places.sqlite", bookmarks: "places.sqlite" },
          "safari" => { history: "History.db", bookmarks: "Bookmarks.plist" }
        }.freeze

        # Relative to the user's home. The first existing root wins, so a
        # macOS path and a Linux path can share one entry.
        ROOTS = {
          "chrome" => ["Library/Application Support/Google/Chrome", ".config/google-chrome"],
          "edge" => ["Library/Application Support/Microsoft Edge", ".config/microsoft-edge"],
          "brave" => ["Library/Application Support/BraveSoftware/Brave-Browser", ".config/BraveSoftware/Brave-Browser"],
          "arc" => ["Library/Application Support/Arc/User Data"],
          "firefox" => ["Library/Application Support/Firefox", ".mozilla/firefox"],
          "safari" => ["Library/Safari"]
        }.freeze

        # Default order when `--browser` isn't given. Safari is last: on
        # macOS its directory exists whether or not the user uses it, and
        # it's the only one that needs Full Disk Access.
        BROWSERS = %w[chrome arc brave edge firefox safari].freeze

        def self.family(browser)
          return "chromium" if CHROMIUM.include?(browser)

          browser
        end

        # @return [String, nil] the first root that exists for `browser`.
        def self.default_root(browser, home: Dir.home)
          ROOTS.fetch(browser, []).map { |rel| File.join(home, rel) }.find { |path| File.directory?(path) }
        end

        # @return [String, nil] the first browser in BROWSERS with a root on
        #   this machine.
        def self.detect(home: Dir.home) = BROWSERS.find { |b| default_root(b, home: home) }

        # @param root [String] the browser's profile root — injectable so
        #   specs (and a live check) point at a fixture or a specific copy.
        # @return [Array<Profile>] every profile under `root` holding at
        #   least one of the allowed files.
        def self.locate(browser, root:)
          family = family(browser)
          return [] unless ALLOWED_FILES.key?(family) && root && File.directory?(root)

          profile_dirs(family, root).filter_map { |dir| profile_for(browser, family, dir) }
        rescue Errno::EPERM, Errno::EACCES => e
          # macOS privacy protection (or a sandbox) refusing even the root
          # listing — reported, never worked around (see Importer).
          raise Sqlite::PermissionDenied, e.message
        end

        # The only directory listing in this module: the profile root's own
        # folder names. Safari has no per-profile folders — its root *is*
        # the profile, so nothing is listed there at all.
        def self.profile_dirs(family, root)
          case family
          when "chromium" then Dir.glob(File.join(root, "{Default,Profile *}"))
          when "firefox"
            profiles = File.directory?(File.join(root, "Profiles")) ? File.join(root, "Profiles") : root
            Dir.glob(File.join(profiles, "*")).select { |d| File.directory?(d) }.sort
          else [root]
          end
        end
        private_class_method :profile_dirs

        def self.profile_for(browser, family, dir)
          files = ALLOWED_FILES.fetch(family)
          history = existing(dir, files[:history])
          bookmarks = existing(dir, files[:bookmarks])
          return nil unless history || bookmarks

          Profile.new(browser: browser, family: family, dir: dir, history: history, bookmarks: bookmarks)
        end
        private_class_method :profile_for

        # A stat, never an open — File.exist? on a name from ALLOWED_FILES
        # only.
        def self.existing(dir, name)
          path = File.join(dir, name)
          File.exist?(path) ? path : nil
        end
        private_class_method :existing
      end
    end
  end
end

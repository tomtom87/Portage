require_relative "../browser_import/profiles"

module Portage
  module Cli
    module BrowserProfile
      # Where to find a Chromium-family browser's own executable, and
      # which family is supported at all (docs/plans/
      # buy-skill-and-local-browser.md Phase 6). Firefox/Safari are out of
      # scope for driving (see the plan's Phase 6 section) even though
      # BrowserImport::Profiles already knows their profile roots — this
      # module only ever launches one of CHROMIUM.
      module Browsers
        CHROMIUM = BrowserImport::Profiles::CHROMIUM

        # macOS app bundle executables. The first existing path wins.
        MAC_APPS = {
          "chrome" => "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          "edge" => "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
          "brave" => "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
          "arc" => "/Applications/Arc.app/Contents/MacOS/Arc"
        }.freeze

        # Linux binary names, tried on PATH. Arc has no Linux build.
        LINUX_BINARIES = {
          "chrome" => %w[google-chrome google-chrome-stable chromium chromium-browser],
          "edge" => %w[microsoft-edge microsoft-edge-stable],
          "brave" => %w[brave-browser brave-browser-stable],
          "arc" => []
        }.freeze

        # @param path [String] PATH-shaped, injectable so a spec can point
        #   ".which" at a fixture directory instead of mutating ENV.
        # @return [String, nil] the first launchable binary for `browser`
        #   on this machine, or nil when it isn't installed.
        def self.binary_for(browser, darwin: RUBY_PLATFORM.include?("darwin"), path: ENV.fetch("PATH", ""))
          mac_binary(browser, darwin) || linux_binary(browser, path)
        end

        def self.mac_binary(browser, darwin)
          return nil unless darwin

          path = MAC_APPS[browser]
          path if path && File.exist?(path)
        end
        private_class_method :mac_binary

        def self.linux_binary(browser, path)
          LINUX_BINARIES.fetch(browser, []).filter_map { |name| which(name, path) }.first
        end
        private_class_method :linux_binary

        def self.which(cmd, path)
          path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, cmd) }
                                          .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        end
        private_class_method :which

        # @return [String, nil] the first CHROMIUM browser that's actually
        #   installed on this machine, reusing BrowserImport::Profiles's
        #   own "does this browser's default profile root exist" check
        #   purely as an installed-or-not signal — nothing under that root
        #   is ever read here.
        def self.detect(home: Dir.home)
          CHROMIUM.find { |b| BrowserImport::Profiles.default_root(b, home: home) }
        end
      end
    end
  end
end

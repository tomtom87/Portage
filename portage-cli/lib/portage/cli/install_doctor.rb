require "rbconfig"
require_relative "version"

module Portage
  module Cli
    # Phase 4 of docs/plans/homebrew-distribution.md's `doctor` checks: how
    # this copy of portage-cli was installed (Homebrew formula or plain
    # `gem install`), which Ruby it runs on, which first-party adapter gems
    # it can load, and whether the `portage` a shell would actually run is
    # this one.
    #
    # That last check is the one that matters. The formula installs into its
    # own Cellar keg, and a `gem install portage-cli` copy in a mise/rbenv/
    # asdf/rvm Ruby's bin usually comes earlier on PATH, so `portage` in a
    # shell silently keeps running the old gem after `brew install` or
    # `brew upgrade` (Homebrew's own caveat hit exactly this on the
    # maintainer's machine). Homebrew's `bin/portage` is a symlink into the
    # Cellar, whose env_script wrapper execs the libexec binary, so every
    # comparison here is between canonical Cellar locations, never raw PATH
    # entries.
    #
    # Everything is read from the filesystem and the process: no `brew`
    # shell-out, no network, so doctor stays fast and works offline (the
    # formula's `test do` block runs it in Homebrew's sandbox).
    class InstallDoctor
      DEFAULT_HOMEBREW_PREFIXES = %w[/opt/homebrew /usr/local /home/linuxbrew/.linuxbrew].freeze
      ADAPTER_GEMS = %w[shopify wix woocommerce bigcommerce magento etsy instagram webmcp decision]
                     .map { |name| "portage-ucp-#{name}" }.freeze
      EXECUTABLE = "portage".freeze

      def self.homebrew_prefixes
        [ENV.fetch("HOMEBREW_PREFIX", nil), *DEFAULT_HOMEBREW_PREFIXES].reject { |p| p.to_s.empty? }.uniq
      end

      # @param path [String] PATH to search for `portage` executables.
      # @param homebrew_prefixes [Array<String>] candidate HOMEBREW_PREFIXes.
      # @param gem_dir [String] this gem's own directory (its `lib/`'s parent).
      # @param ruby [String] the running Ruby's executable path.
      # @param adapter_probe [#call] gem name -> { installed:, loadable:, version:, error: }.
      def initialize(path: ENV.fetch("PATH", ""), homebrew_prefixes: self.class.homebrew_prefixes,
                     gem_dir: File.expand_path("../../..", __dir__), ruby: RbConfig.ruby,
                     adapter_probe: method(:probe_adapter))
        @path = path
        @homebrew_prefixes = homebrew_prefixes.map { |prefix| canonical(prefix) }
        @gem_dir = canonical(gem_dir)
        @ruby = ruby
        @adapter_probe = adapter_probe
      end

      def findings
        [install_finding, runtime_finding, adapters_finding, path_finding].compact
      end

      # @return [String, nil] the HOMEBREW_PREFIX this copy runs from, nil for a gem install.
      def homebrew_prefix
        return @homebrew_prefix if defined?(@homebrew_prefix)

        @homebrew_prefix = @homebrew_prefixes.find do |prefix|
          [@gem_dir, canonical(@ruby)].any? { |dir| under?(dir, keg_root(prefix)) }
        end
      end

      def homebrew? = !homebrew_prefix.nil?

      private

      # --- install method -------------------------------------------------

      def install_finding
        method = homebrew? ? "homebrew" : "gem"
        path = homebrew? ? installed_keg : @gem_dir
        details = { method: method, path: path }
        details[:prefix] = homebrew_prefix if homebrew?
        info("install", "#{method} (#{path})", details)
      end

      def keg_root(prefix) = File.join(prefix, "Cellar", "portage")

      # `<prefix>/Cellar/portage/<version>`, the keg this copy lives in.
      def installed_keg
        root = keg_root(homebrew_prefix)
        version = @gem_dir.delete_prefix("#{root}/").split("/").first
        File.join(root, version)
      end

      # --- runtime --------------------------------------------------------

      def runtime_finding
        info("runtime", "Ruby #{RUBY_VERSION} (#{@ruby}), portage-cli #{VERSION}",
             { ruby_version: RUBY_VERSION, ruby_path: @ruby, portage_cli_version: VERSION })
      end

      # --- adapters -------------------------------------------------------

      # A gem install without adapters is normal: `gem install portage-cli`
      # pulls in none of them, and you add the ones you use. The formula
      # bundles every one, so a Homebrew install missing one is broken.
      def adapters_finding
        report = AdapterReport.new(ADAPTER_GEMS.map { |name| { name: name }.merge(safe_probe(name)) })
        details = { adapters: report.adapters }
        return warning("adapters", report.homebrew_missing_message, details) if homebrew? && report.missing?

        info("adapters", report.summary, details)
      end

      def safe_probe(name)
        @adapter_probe.call(name)
      rescue StandardError, ScriptError => e
        { installed: true, loadable: false, version: nil, error: "#{e.class}: #{e.message}" }
      end

      def probe_adapter(name)
        specs = Gem::Specification.find_all_by_name(name)
        return { installed: false, loadable: false, version: nil } if specs.empty?

        require "portage/ucp/#{name.delete_prefix('portage-ucp-')}"
        spec = Gem.loaded_specs[name] || specs.max_by(&:version)
        { installed: true, loadable: true, version: spec.version.to_s }
      end

      # --- PATH shadowing -------------------------------------------------

      def path_finding
        candidates = path_candidates
        return if candidates.empty?

        details = { first: candidates.first[:path], candidates: candidates }
        message = shadow_message(candidates.first)
        return warning("path", message, details) if message

        # Only a Homebrew keg can be matched to this copy for certain; a gem
        # install's binstub can sit behind a mise/rbenv shim.
        suffix = homebrew? ? " (this install)" : ""
        info("path", "`portage` on PATH is #{candidates.first[:path]}#{suffix}", details)
      end

      # Every `portage` on PATH, first match first, one entry per real file:
      # the same Homebrew bin can sit on PATH twice, and `bin/portage` and
      # `opt/portage/bin/portage` both resolve to one keg.
      def path_candidates
        candidates = @path.split(File::PATH_SEPARATOR).reject(&:empty?).filter_map { |dir| candidate(dir) }
        candidates.uniq { |c| c[:realpath] }
      end

      def candidate(dir)
        file = File.join(dir, EXECUTABLE)
        return unless File.file?(file) && File.executable?(file)

        real = canonical(file)
        { path: file, realpath: real, kind: homebrew_keg?(real) ? "homebrew" : "other" }
      end

      def shadow_message(first)
        if homebrew?
          return if under?(first[:realpath], keg_root(homebrew_prefix))

          homebrew_shadowed_message(first)
        elsif first[:kind] == "homebrew"
          gem_shadowed_message(first)
        end
      end

      def homebrew_shadowed_message(first)
        brew_bin = File.join(homebrew_prefix, "bin")
        "`portage` on PATH runs #{first[:path]}, not this Homebrew install (#{brew_bin}/portage), " \
          "so `brew upgrade portage` won't change what your shell runs. Check with `which -a portage`. " \
          "Fix: if that's a `gem install` copy, run `gem uninstall portage-cli` with that Ruby active; " \
          "or put #{brew_bin} ahead of #{File.dirname(first[:path])} in PATH."
      end

      def gem_shadowed_message(first)
        "`portage` on PATH runs the Homebrew install (#{first[:path]}), not this gem install " \
          "(#{@gem_dir}). Check with `which -a portage`. Fix: keep one — `brew uninstall portage` " \
          "to use the gem, or `gem uninstall portage-cli` to use Homebrew; or reorder PATH."
      end

      def homebrew_keg?(realpath)
        @homebrew_prefixes.any? { |prefix| under?(realpath, keg_root(prefix)) }
      end

      # --- helpers --------------------------------------------------------

      def under?(path, root) = path.start_with?("#{root}/")

      def canonical(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def info(check, message, details) = finding(check, message, details, "info")
      def warning(check, message, details) = finding(check, message, details, "warning")

      def finding(check, message, details, level)
        Doctor::Finding.new(check: check, message: message, level: level, details: details)
      end
    end

    # The adapters line of InstallDoctor's report, one probe result per gem:
    # `{ name:, installed:, loadable:, version:, error: }`.
    class InstallDoctor
      class AdapterReport
        attr_reader :adapters

        def initialize(adapters)
          @adapters = adapters
        end

        def missing = @adapters.reject { |a| a[:loadable] }
        def missing? = missing.any?

        def summary
          loaded, broken, absent = partitioned
          parts = [loaded.empty? ? "none loadable" : loaded.map { |a| "#{short(a)} #{a[:version]}" }.join(", ")]
          parts << "failed to load: #{names(broken)}" unless broken.empty?
          parts << "not installed: #{names(absent)}" unless absent.empty?
          parts.join("; ")
        end

        def homebrew_missing_message
          described = missing.map { |a| a[:error] ? "#{short(a)} (#{a[:error]})" : short(a) }
          "This Homebrew install bundles every adapter, but #{described.join(', ')} can't be loaded — " \
            "reinstall with `brew reinstall portage`."
        end

        private

        def partitioned
          loaded, rest = @adapters.partition { |a| a[:loadable] }
          broken, absent = rest.partition { |a| a[:installed] }
          [loaded, broken, absent]
        end

        def names(adapters) = adapters.map { |a| short(a) }.join(", ")
        def short(adapter) = adapter[:name].delete_prefix("portage-ucp-")
      end
    end
  end
end

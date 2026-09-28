require_relative "sources/shopify_catalog"
require_relative "sources/stores_file"
require_relative "sources/browser"
require_relative "sources/wikidata"
require_relative "sources/webmcp_sweep"

module Portage
  module Cli
    module Index
      # One small file per source under index/sources/ — `portage index
      # sources` lists exactly this registry, so what the command shows and
      # what `index build` can actually run never drift apart.
      module Sources
        ALL = {
          "shopify_catalog" => -> { ShopifyCatalog.new },
          "stores_file" => -> { StoresFile.new },
          "browser" => -> { Browser.new },
          "wikidata" => -> { Wikidata.new },
          "webmcp_sweep" => -> { WebmcpSweep.new }
        }.freeze

        # Runs with no extra opt-in: no bridge required, and no low-yield
        # trade-off to accept up front. `wikidata` and `webmcp_sweep` still
        # show up in `portage index sources`, just not run unless named in
        # `--sources`. `browser` is listed but never a default — it yields
        # nothing; `portage browser import` writes those entries itself
        # (see Sources::Browser).
        DEFAULT_NAMES = %w[shopify_catalog stores_file].freeze

        def self.all = ALL.values.map(&:call)

        def self.default = DEFAULT_NAMES.map { |n| build(n) }

        # @param names [Array<String>]
        # @return [Array<#name, #description, #source_path, #candidates>]
        #   unknown names are silently dropped — callers report them
        #   themselves (see Cli's own option-parsing errors elsewhere).
        def self.by_name(names) = Array(names).filter_map { |n| build(n) }

        def self.build(name) = ALL[name]&.call
      end
    end
  end
end

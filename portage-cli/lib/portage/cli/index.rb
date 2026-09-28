require_relative "index/store"
require_relative "index/product_store"
require_relative "index/known_cache"
require_relative "index/sources"
require_relative "index/builder"

module Portage
  module Cli
    # `portage index` — a local store and product index the user builds
    # themselves (docs/plans/buy-skill-and-local-browser.md Phase 2b),
    # feeding `find` a fresh install's stores.yml can't. Never checked into
    # git; never trusted the way stores.yml is (see Index::Store's own
    # comment). Phase 2c adds the repo's own jsdelivr-hosted known-stores
    # list (Index::KnownCache), fetched under the user's own entries here —
    # never in place of them.
    module Index
      DIR = File.join(Dir.home, ".portage", "index").freeze
    end
  end
end

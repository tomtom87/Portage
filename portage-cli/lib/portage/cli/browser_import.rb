require_relative "browser_import/filter"
require_relative "browser_import/profiles"
require_relative "browser_import/sqlite"
require_relative "browser_import/plist_xml"
require_relative "browser_import/readers"
require_relative "browser_import/prober"
require_relative "browser_import/importer"
require_relative "browser_import/confirm"

module Portage
  module Cli
    # `portage browser import` — bookmarks and history as index seeds
    # (docs/plans/buy-skill-and-local-browser.md Phase 3, Tier A). Opt-in,
    # local-only, reduced to shop domains, and shown to the user before
    # anything is saved. Never reads a browser's password, cookie or
    # autofill store (see Profiles::ALLOWED_FILES), never attaches to or
    # drives the browser, and never sends anything about the user's
    # history anywhere except one `/.well-known/ucp` probe per unknown
    # domain (Prober).
    module BrowserImport
    end
  end
end

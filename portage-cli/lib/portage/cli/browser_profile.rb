require_relative "browser_profile/errors"
require_relative "browser_profile/browsers"
require_relative "browser_profile/cdp"
require_relative "browser_profile/cdp_socket"
require_relative "browser_profile/allowlist"
require_relative "browser_profile/bridge"
require_relative "browser_profile/launcher"
require_relative "browser_profile/profile"

module Portage
  module Cli
    # `portage browser profile init|open|status` — the Portage browser
    # profile (docs/plans/buy-skill-and-local-browser.md Phase 6, Tier B).
    # A dedicated Chromium-family profile directory under
    # ~/.portage/browser/, never the browser's own default profile, that
    # `portage buy --handoff-target profile` drives as a WebMCP bridge
    # (see Bridge) limited to a domain allowlist (Allowlist) — the store
    # being bought from, plus its checkout host once known. The user signs
    # into their shopping sites in it once; Portage never reads a
    # credential/cookie/autofill store from it, never touches a payment
    # field, and never clicks pay.
    module BrowserProfile
    end
  end
end

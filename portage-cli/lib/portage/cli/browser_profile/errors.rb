module Portage
  module Cli
    module BrowserProfile
      # Base for everything this feature raises — a caller (cli.rb, Buy)
      # can rescue this one class instead of naming each subclass.
      class Error < StandardError; end

      # `Browsers.binary_for` found nothing installed for the requested
      # browser.
      class BrowserNotFoundError < Error; end

      # The profile process never answered its own CDP endpoint within the
      # launch wait — a slow machine, a browser that failed to start, or a
      # port already held by something else.
      class LaunchError < Error; end

      # docs/plans/buy-skill-and-local-browser.md Phase 6: driving stayed
      # inside the allowed domains (the store being bought from, plus its
      # checkout host once known) or this stopped the run rather than
      # continue on an unexpected host. Never rescued into "try again
      # somewhere else" — the whole point is that nothing here recovers by
      # itself.
      class DomainNotAllowedError < Error; end
    end
  end
end

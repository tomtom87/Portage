module Portage
  module Cli
    # The one shell-out that opens a URL in the shopper's browser, shared by
    # CheckoutHandoff (a dead-end checkout's auto-open) and ProductPage
    # (docs/plans/human-pick-and-approve.md Phase 2's "view the product
    # page"). Mixed in rather than called as a module function so `system`
    # stays the including object's own — specs stub it per instance.
    #
    # No new gem for the actual open — every other shell-out in this repo
    # (PaymentMethods::KeychainBackend, SecretServiceBackend) hand-rolls
    # `system` rather than pulling in launchy for something the OS already
    # provides. `system(cmd, url)` (array form, never an interpolated
    # string) so a merchant-controlled URL can't inject into a shell.
    # Whether a URL is safe to open at all is the caller's check.
    module BrowserOpener
      private

      # @return [Boolean] whether the browser was actually opened.
      def open_browser(url)
        command = platform_command
        return false unless command

        !!system(command, url)
      rescue StandardError => e
        warn "portage: couldn't open #{url} (#{e.message})"
        false
      end

      def platform_command
        case RbConfig::CONFIG["host_os"]
        when /darwin/i then "open"
        when /linux|bsd/i then "xdg-open"
        when /mswin|mingw|cygwin/i then "start"
        end
      end
    end
  end
end

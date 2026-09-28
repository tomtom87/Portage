require "fileutils"
require_relative "browsers"
require_relative "cdp"
require_relative "errors"
require_relative "launcher"

module Portage
  module Cli
    module BrowserProfile
      # `portage browser profile init|open|status` (docs/plans/
      # buy-skill-and-local-browser.md Phase 6): a dedicated Chromium
      # profile directory under ~/.portage/browser/<browser>/profile,
      # launched with remote debugging bound to that profile only —
      # never the browser's own default profile, and never a directory
      # this class didn't create itself. The user signs into their
      # shopping sites in this profile once; nothing here ever reads a
      # credential, cookie or autofill store from it (that's Chromium's
      # own job once the shopper is looking at the page).
      class Profile
        ROOT = File.join(Dir.home, ".portage", "browser").freeze
        DEFAULT_PORT = 9223

        attr_reader :browser, :port, :dir

        def initialize(browser: "chrome", root: ROOT, port: DEFAULT_PORT, launcher: Launcher.new, cdp: Cdp,
                       poll_attempts: 20, poll_interval: 0.25, sleep_fn: ->(s) { sleep s })
          raise ArgumentError, "unsupported browser #{browser.inspect} (want one of #{Browsers::CHROMIUM})" unless
            Browsers::CHROMIUM.include?(browser)

          @browser = browser
          @dir = File.join(root, browser, "profile")
          @port = port
          @launcher = launcher
          @cdp = cdp
          @poll_attempts = poll_attempts
          @poll_interval = poll_interval
          @sleep_fn = sleep_fn
        end

        # Never launches anything — just makes sure the dedicated profile
        # directory exists, so `portage browser profile open` always has
        # somewhere of its own to point `--user-data-dir` at.
        def init!
          FileUtils.mkdir_p(@dir)
          { browser: @browser, dir: @dir, port: @port, created: true }
        end

        # @return [Hash] `running:` plus, when running, whatever
        #   `/json/version` reports (Browser, protocolVersion, …) — no
        #   HTTP request is ever made to anything but 127.0.0.1:`port`.
        def status
          version = @cdp.version(port: @port)
          base = { running: !version.nil?, browser: @browser, dir: @dir, port: @port }
          version ? base.merge(version) : base
        end

        # Launches the browser if it isn't already running on this
        # profile's port, then either opens a new tab at `url` or hands
        # back the first existing tab. Idempotent: calling this against an
        # already-running profile just attaches.
        def open!(url: nil)
          launch! unless status[:running]
          attach(url)
        end

        private

        def launch!
          binary = Browsers.binary_for(@browser)
          raise BrowserNotFoundError, "#{@browser} isn't installed on this machine" unless binary

          FileUtils.mkdir_p(@dir)
          @launcher.launch(binary: binary, profile_dir: @dir, port: @port)
          wait_until_running!
        end

        def wait_until_running!
          @poll_attempts.times do
            return true if status[:running]

            @sleep_fn.call(@poll_interval)
          end
          raise LaunchError, "#{@browser} didn't answer its remote-debugging port (#{@port}) in time"
        end

        def attach(url)
          target = url ? @cdp.new_tab(port: @port, url: url) : @cdp.list(port: @port).first
          { running: true, browser: @browser, dir: @dir, port: @port, target: target }
        end
      end
    end
  end
end

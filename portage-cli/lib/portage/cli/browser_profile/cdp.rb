require "net/http"
require "uri"
require "json"
require "portage/ucp/support/connection"

module Portage
  module Cli
    module BrowserProfile
      # The plain-HTTP half of Chrome DevTools Protocol: the
      # `http://127.0.0.1:<port>/json/*` endpoints every Chromium browser
      # exposes once started with `--remote-debugging-port`. Used for
      # "is the profile running, and what tab is it on" (`.version`/
      # `.list`) and to open a tab already navigated to a URL (`.new_tab`)
      # without needing the WebSocket layer (CdpSocket) at all for that.
      #
      # Every call is read-only against the local debugging port, GET/PUT
      # requests only, `route: :probe` (same route category ProbeCache's
      # own `/.well-known/ucp` probes use) so it's subject to whatever
      # proxy config a `--no-proxy` list already exempts localhost from.
      # A failure (not running, timeout, bad JSON) returns nil rather than
      # raising — callers (Profile) decide what that means.
      module Cdp
        TIMEOUT = 3
        HOST = "127.0.0.1".freeze

        def self.version(port:, host: HOST) = get(host, port, "/json/version")

        def self.list(port:, host: HOST) = Array(get(host, port, "/json/list"))

        # Opens a new tab already navigated to `url` — Chrome's own
        # `/json/new?<url>` endpoint, a PUT since it creates something
        # server-side.
        def self.new_tab(port:, url:, host: HOST)
          get(host, port, "/json/new?#{URI.encode_www_form_component(url)}", method: :put)
        end

        # `/json/close/<id>` answers plain text ("Target is closing"), not
        # JSON — checked by success status only, never parsed as JSON.
        def self.close_tab(port:, id:, host: HOST)
          uri = URI("http://#{host}:#{port}/json/close/#{id}")
          fetch(uri, :get).is_a?(Net::HTTPSuccess)
        rescue StandardError
          false
        end

        def self.get(host, port, path, method: :get)
          uri = URI("http://#{host}:#{port}#{path}")
          response = fetch(uri, method)
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue StandardError
          nil
        end
        private_class_method :get

        def self.fetch(uri, method)
          Portage::Ucp::Support::Connection.start(uri, route: :probe, open_timeout: TIMEOUT,
                                                       read_timeout: TIMEOUT) do |http|
            method == :put ? http.request(Net::HTTP::Put.new(uri.request_uri)) : http.get(uri.request_uri)
          end
        end
        private_class_method :fetch
      end
    end
  end
end

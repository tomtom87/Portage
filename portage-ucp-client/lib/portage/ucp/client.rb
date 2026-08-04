require "net/http"
require "uri"
require "json"
require "mcp"
require "portage/ucp"

require_relative "client/version"
require_relative "client/errors"
require_relative "client/tool_result"
require_relative "client/session"
require_relative "client/transports/loopback"
require_relative "client/transports/stdio"
require_relative "client/transports/http"

module Portage
  module Ucp
    # Client-side counterpart to the rest of portage-ucp: everything else in
    # this repo lets a Ruby program *expose* a commerce backend to agents
    # (server side). This gem lets a Ruby program *act as* the shopper's
    # agent — discover somebody else's manifest, or drive an owner's own
    # Adapter directly, and place an order.
    module Client
      MANIFEST_PATH = "/.well-known/ucp".freeze

      # Wraps an already-built Adapter directly — no subprocess/socket. Still
      # runs the real merchant-side contract (authenticator, rate limiter,
      # Dispatcher, WireEnvelope, via Portage::Ucp::Mcp::Server), just
      # in-process. This is the transport for the "your own store" case: you
      # already have credentials for this Adapter, so there's no manifest to
      # discover and no wire hop to make.
      def self.for_adapter(adapter, **server_opts)
        Session.new(transport: Transports::Loopback.new(adapter: adapter, **server_opts))
      end

      # Connects over stdio (a subprocess) or Streamable HTTP (a URL) — pass
      # exactly one of `command:` or `url:`.
      def self.connect(command: nil, args: [], env: nil, url: nil, headers: {}, capabilities: nil)
        transport = if command
                      Transports::Stdio.new(command: command, args: args, env: env)
                    elsif url
                      Transports::Http.new(url: url, headers: headers)
                    else
                      raise ArgumentError, "connect requires either command: or url:"
                    end
        Session.new(transport: transport, capabilities: capabilities)
      end

      # GETs `<url>/.well-known/ucp`, parses the manifest, and connects to the
      # `mcp`-transport endpoint it advertises in `services` (see
      # Portage::Ucp::Manifest#services — the core-gem fix this client
      # depends on to know where to connect).
      # @return [Session] scoped to the manifest's advertised capabilities.
      def self.discover(url)
        manifest = fetch_manifest(url)
        connect(url: mcp_endpoint(manifest), capabilities: capability_names(manifest))
      end

      def self.fetch_manifest(url)
        uri = URI.parse("#{url.to_s.sub(%r{/\z}, '')}#{MANIFEST_PATH}")
        response = Net::HTTP.get_response(uri)
        raise DiscoveryError, "GET #{uri} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise DiscoveryError, "manifest at #{url} is not valid JSON: #{e.message}"
      rescue DiscoveryError
        raise
      rescue StandardError => e
        raise DiscoveryError, "couldn't reach #{url}: #{e.class}: #{e.message}"
      end
      private_class_method :fetch_manifest

      def self.mcp_endpoint(manifest)
        service = Array(manifest["services"]).find { |s| s["transport"] == "mcp" }
        endpoint = service && service["endpoint"]
        raise DiscoveryError, "manifest has no mcp service entry to connect to" unless endpoint

        endpoint
      end
      private_class_method :mcp_endpoint

      def self.capability_names(manifest)
        Array(manifest["capabilities"]).map { |c| c["name"] }
      end
      private_class_method :capability_names
    end
  end
end

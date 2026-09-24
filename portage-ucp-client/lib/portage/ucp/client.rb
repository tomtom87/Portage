require "net/http"
require "uri"
require "json"
require "mcp"
require "portage/ucp"

require_relative "client/version"
require_relative "client/errors"
require_relative "client/tool_result"
require_relative "client/session"
require_relative "client/transports/local_arguments"
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
      # Sent on every request this gem makes to a store (the manifest GET and
      # each Streamable HTTP call) unless the caller's own headers name one,
      # so a merchant reading its logs can tell a Portage agent from Ruby's
      # or Faraday's default and find out what it is.
      USER_AGENT = "portage-ucp-client/#{VERSION} (+https://github.com/tomtom87/Portage)".freeze

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
      # @param proxy [String, Hash, nil] forwarded to Transports::Http (a
      #   `url:` connection only) — see its own doc comment.
      def self.connect(command: nil, args: [], env: nil, url: nil, headers: {}, capabilities: nil, proxy: nil)
        transport = if command
                      Transports::Stdio.new(command: command, args: args, env: env)
                    elsif url
                      Transports::Http.new(url: url, headers: headers, proxy: proxy)
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
      # @param headers [Hash{String => String}] sent with the manifest GET
      #   and every call after it — e.g. a "User-Agent" naming the app
      #   built on this gem.
      # @param proxy [String, Hash, nil] forwarded to the Streamable HTTP
      #   connection this discovers into — see Transports::Http.
      def self.discover(url, headers: {}, proxy: nil)
        manifest = fetch_manifest(url, headers)
        connect(url: mcp_endpoint(manifest), headers: headers, capabilities: capability_names(manifest), proxy: proxy)
      end

      def self.fetch_manifest(url, headers = {})
        uri = URI.parse("#{url.to_s.sub(%r{/\z}, '')}#{MANIFEST_PATH}")
        response = Net::HTTP.get_response(uri, with_user_agent(headers))
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

      # USER_AGENT unless `headers` already names one, in any case.
      def self.with_user_agent(headers)
        return headers if headers.keys.any? { |name| name.to_s.casecmp?("user-agent") }

        { "User-Agent" => USER_AGENT }.merge(headers)
      end

      # Real UCP manifests (confirmed live on Casper, Allbirds, Glossier, and
      # 34+ other Shopify UCP rollouts as of "2026-08-25") nest everything one
      # level deeper under a "ucp" key. This gem's own server side
      # (Portage::Ucp::Manifest) still emits the old flat shape, so both are
      # supported rather than picking one — see docs/well-known-ucp.md.
      def self.ucp_section(manifest)
        manifest["ucp"] || manifest
      end
      private_class_method :ucp_section

      def self.mcp_endpoint(manifest)
        services = ucp_section(manifest)["services"]
        entries = services.is_a?(Hash) ? services.values.flatten : Array(services)
        endpoint = entries.select { |s| s["transport"] == "mcp" }
                          .max_by { |s| s["version"].to_s }
                          &.fetch("endpoint", nil)
        raise ManifestShapeError, "manifest has no mcp service entry to connect to" unless endpoint

        endpoint
      end
      private_class_method :mcp_endpoint

      def self.capability_names(manifest)
        capabilities = ucp_section(manifest)["capabilities"]
        capabilities.is_a?(Hash) ? capabilities.keys : Array(capabilities).map { |c| c["name"] }
      end
      private_class_method :capability_names
    end
  end
end

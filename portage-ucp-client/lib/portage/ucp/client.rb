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
require_relative "client/transports/rest"

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

      # Connects over stdio (a subprocess), Streamable HTTP (a URL) or REST (a
      # URL with `transport: :rest`) — pass exactly one of `command:` or `url:`.
      # @param transport [Symbol] `:mcp` (default) or `:rest`; only for `url:`.
      # @param proxy [String, Hash, nil] forwarded to Transports::Http (a
      #   `url:` connection only) — see its own doc comment.
      # @param common [Array(Symbol, String), nil] `[transport, endpoint]` of
      #   the `dev.ucp.common` service when it differs from `url`'s; `ask`
      #   then opens its own connection to it on first use (same headers and
      #   proxy).
      def self.connect(command: nil, args: [], env: nil, url: nil, headers: {}, capabilities: nil, proxy: nil,
                       transport: :mcp, common: nil)
        unless %i[mcp rest].include?(transport)
          raise ArgumentError, "transport must be :mcp or :rest, got #{transport.inspect}"
        end

        raise ArgumentError, "transport: :rest needs url:, not command:" if command && transport == :rest

        wire = if command
                 Transports::Stdio.new(command: command, args: args, env: env)
               elsif url
                 url_transport(transport, url, headers, proxy)
               else
                 raise ArgumentError, "connect requires either command: or url:"
               end
        common_wire = common && -> { url_transport(common[0], common[1], headers, proxy) }
        Session.new(transport: wire, capabilities: capabilities, transport_name: transport,
                    common_transport: common_wire)
      end

      def self.url_transport(transport, url, headers, proxy)
        (transport == :rest ? Transports::Rest : Transports::Http).new(url: url, headers: headers, proxy: proxy)
      end
      private_class_method :url_transport

      # GETs `<url>/.well-known/ucp`, parses the manifest, and connects to the
      # `mcp`-transport endpoint it advertises in `services` (else its `rest`
      # one; see Portage::Ucp::Manifest#services — the core-gem fix this client
      # depends on to know where to connect).
      # @return [Session] scoped to the manifest's advertised capabilities.
      # @param headers [Hash{String => String}] sent with the manifest GET
      #   and every call after it — e.g. a "User-Agent" naming the app
      #   built on this gem.
      # @param proxy [String, Hash, nil] forwarded to the Streamable HTTP
      #   connection this discovers into — see Transports::Http.
      def self.discover(url, headers: {}, proxy: nil)
        manifest = fetch_manifest(url, headers)
        transport, endpoint = service_endpoint(manifest)
        common = common_endpoint(manifest)
        connect(url: endpoint, headers: headers, capabilities: capability_names(manifest), proxy: proxy,
                transport: transport, common: (common unless common == [transport, endpoint]))
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
      # level deeper under a "ucp" key. Portage::Ucp::Manifest has emitted
      # the same nested shape since portage-ucp 0.8.0. The flat fallback
      # stays for stores still serving a manifest from an older portage-ucp:
      # there, services and capabilities sit at the top level and
      # capabilities is an array of {name:, version:}. This gem needing
      # portage-ucp 0.8 says nothing about what a store runs, so dropping
      # the fallback would break discovery against those stores — see
      # docs/well-known-ucp.md.
      def self.ucp_section(manifest)
        manifest["ucp"] || manifest
      end
      private_class_method :ucp_section

      # MCP when the store offers it, else REST; the newest `version` wins
      # within a transport.
      # @return [Array(Symbol, String)] `[:mcp | :rest, endpoint]`
      def self.service_endpoint(manifest)
        services = ucp_section(manifest)["services"]
        entries = services.is_a?(Hash) ? services.values.flatten : Array(services)
        %w[mcp rest].each do |transport|
          endpoint = newest_endpoint(entries, transport)
          return [transport.to_sym, endpoint] if endpoint
        end
        seen = entries.map { |s| s["transport"] }.compact.uniq
        raise ManifestShapeError, "manifest has no mcp or rest service entry to connect to (saw: #{seen.join(', ')})"
      end
      private_class_method :service_endpoint

      # `[transport, endpoint]` of the `dev.ucp.common` service, picked like
      # service_endpoint, or nil when the manifest has none (or the services
      # list isn't keyed by service name).
      def self.common_endpoint(manifest)
        services = ucp_section(manifest)["services"]
        return unless services.is_a?(Hash)

        entries = Array(services["dev.ucp.common"])
        %w[mcp rest].each do |transport|
          endpoint = newest_endpoint(entries, transport)
          return [transport.to_sym, endpoint] if endpoint
        end
        nil
      end
      private_class_method :common_endpoint

      def self.newest_endpoint(entries, transport)
        entries.select { |s| s["transport"] == transport }.max_by { |s| s["version"].to_s }&.fetch("endpoint", nil)
      end
      private_class_method :newest_endpoint

      def self.capability_names(manifest)
        capabilities = ucp_section(manifest)["capabilities"]
        capabilities.is_a?(Hash) ? capabilities.keys : Array(capabilities).map { |c| c["name"] }
      end
      private_class_method :capability_names
    end
  end
end

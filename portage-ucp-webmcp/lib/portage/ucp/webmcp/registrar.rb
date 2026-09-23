module Portage
  module Ucp
    module WebMcp
      # Renders assets/registrar.js for one ToolCatalog: the page script that
      # registers the catalog's tools on `document.modelContext` and routes
      # each call to `endpoint` (a Rack::CallEndpoint). Serve it with
      # Rack::App/Rack::ScriptEndpoint, or inline it via #to_js yourself.
      class Registrar
        PLACEHOLDER = "__PORTAGE_WEBMCP_CONFIG__".freeze
        CREDENTIALS = %w[same-origin include omit].freeze

        # @param endpoint [String] URL the page POSTs tools/call to; relative
        #   URLs resolve against the page, like any fetch.
        # @param credentials [String] fetch `credentials` mode — the
        #   Authenticator on the other end sees whatever cookies this lets
        #   through. "include" is only needed for a cross-origin endpoint.
        # @param headers [Hash] extra request headers (e.g. a CSRF token the
        #   host app's Authenticator checks).
        # @param exposed_to [Array<String>, nil] WebMCP `exposedTo` origins,
        #   for tools a cross-origin agent frame should also see.
        # @param include_polyfill [Boolean] prepend assets/polyfill.js, so
        #   browsers without native WebMCP still get a spec-shaped
        #   `document.modelContext` for an agent-driven browser to read.
        def initialize(catalog:, endpoint:, credentials: "same-origin", headers: {}, exposed_to: nil,
                       include_polyfill: false)
          valid = CREDENTIALS.include?(credentials)
          raise ArgumentError, "credentials must be one of #{CREDENTIALS.join(', ')}" unless valid

          @catalog = catalog
          @endpoint = endpoint
          @credentials = credentials
          @headers = headers
          @exposed_to = exposed_to
          @include_polyfill = include_polyfill
        end

        def config
          {
            "endpoint" => @endpoint, "credentials" => @credentials,
            "headers" => @headers.to_h { |k, v| [k.to_s, v.to_s] },
            "exposedTo" => @exposed_to,
            "tools" => @catalog.tools
          }.compact
        end

        def to_js
          script = Assets.read("registrar.js").sub(PLACEHOLDER) { Assets.inline_json(config) }
          @include_polyfill ? "#{Assets.read('polyfill.js')}\n#{script}" : script
        end
      end
    end
  end
end

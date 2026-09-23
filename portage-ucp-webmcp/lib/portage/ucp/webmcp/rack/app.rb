require "rack"

module Portage
  module Ucp
    module WebMcp
      module Rack
        # Both halves of the inbound bridge behind one mountable Rack app:
        #
        #   GET  <mount>/webmcp.js  — the page registrar (ScriptEndpoint)
        #   POST <mount>/webmcp     — its tool calls (CallEndpoint)
        #
        # The registrar's endpoint is derived per request from SCRIPT_NAME, so
        # `mount app, at: "/ucp"` in Rails (or `map "/ucp"` in a config.ru)
        # just works; pass `endpoint:` to point the page somewhere else.
        #
        #   catalog = Portage::Ucp::WebMcp::ToolCatalog.new(adapter: adapter)
        #   run Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog)
        #
        #   <script src="/ucp/webmcp.js" defer></script>
        class App
          DEFAULT_SCRIPT_PATH = "/webmcp.js".freeze
          DEFAULT_CALL_PATH = "/webmcp".freeze

          # @param call_options [Hash] forwarded to CallEndpoint
          #   (allowed_origins:, require_origin:).
          # @param registrar_options [Hash] forwarded to Registrar
          #   (endpoint:, credentials:, headers:, exposed_to:, include_polyfill:).
          def initialize(catalog:, script_path: DEFAULT_SCRIPT_PATH, call_path: DEFAULT_CALL_PATH,
                         call_options: {}, registrar_options: {})
            @catalog = catalog
            @script_path = script_path
            @call_path = call_path
            @registrar_options = registrar_options
            @call_endpoint = CallEndpoint.new(catalog: catalog, **call_options)
            @scripts = {}
            @lock = Mutex.new
          end

          def call(env)
            case env["PATH_INFO"]
            when @script_path then script_endpoint(env).call(env)
            when @call_path then @call_endpoint.call(env)
            else [404, { "content-type" => "application/json" }, ['{"error":"not_found"}']]
            end
          end

          private

          def script_endpoint(env)
            endpoint = @registrar_options[:endpoint] || "#{env['SCRIPT_NAME']}#{@call_path}"
            @lock.synchronize do
              @scripts[endpoint] ||= ScriptEndpoint.new(
                registrar: Registrar.new(catalog: @catalog, **@registrar_options, endpoint: endpoint)
              )
            end
          end
        end
      end
    end
  end
end

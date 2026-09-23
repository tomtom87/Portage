require "rack"

module Portage
  module Ucp
    module WebMcp
      module Rack
        # Serves a Registrar's page script. The page includes it with an
        # ordinary `<script src=... defer>`; nothing else on the page changes.
        class ScriptEndpoint
          HEADERS = {
            "content-type" => "application/javascript; charset=utf-8",
            # Tool set follows the Adapter/registry, so it can change on
            # deploy; revalidate rather than pin a stale set in caches.
            "cache-control" => "no-cache",
            "x-content-type-options" => "nosniff"
          }.freeze

          def initialize(registrar:)
            @registrar = registrar
          end

          def call(env)
            request = ::Rack::Request.new(env)
            return [405, { "allow" => "GET, HEAD" }, []] unless request.get? || request.head?

            body = @registrar.to_js
            [200, HEADERS, request.head? ? [] : [body]]
          end
        end
      end
    end
  end
end

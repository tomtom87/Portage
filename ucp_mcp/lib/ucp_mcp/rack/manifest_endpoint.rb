require "json"
require "rack"

module UcpMcp
  module Rack
    # Rack app serving GET /.well-known/ucp — the signed UCP discovery document.
    # Mount it however suits the consumer's app (in-process or standalone, §7.3);
    # this gem makes no assumption about host framework or process model.
    class ManifestEndpoint
      def initialize(manifest:)
        @manifest = manifest
      end

      def call(env)
        request = ::Rack::Request.new(env)
        return not_found unless request.get?

        [200, { "content-type" => "application/json" }, [JSON.generate(@manifest.to_h)]]
      end

      private

      def not_found
        [404, { "content-type" => "application/json" }, [JSON.generate(error: "not_found")]]
      end
    end
  end
end

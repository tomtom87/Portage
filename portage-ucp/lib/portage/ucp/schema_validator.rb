require "json"
require "json_schemer"

module Portage
  module Ucp
    # Validates data against UCP's own published JSON Schemas / OpenRPC docs —
    # offline, against the copy vendored under schemas/<version>/ (see §13:
    # ucpchecker.com is a manual pre-release check only, never a CI gate; this
    # is the CI-safe equivalent).
    #
    # The vendored tree mirrors https://ucp.dev/<version>/... path-for-path
    # (schemas/2026-04-08/schemas/shopping/cart.json <->
    # https://ucp.dev/2026-04-08/schemas/shopping/cart.json), so every $ref
    # inside a vendored document — however deeply nested — resolves to another
    # vendored file with a single prefix rewrite, no network access needed.
    class SchemaValidator
      def initialize(version: "2026-04-08", root: File.join(__dir__, "..", "..", "..", "schemas"))
        @base_url = "https://ucp.dev/#{version}/"
        @base_dir = File.expand_path(File.join(root, version))
      end

      # @param relative_path [String] e.g. "schemas/shopping/cart.json", matching
      #   the vendored path under schemas/<version>/.
      # @return [Array<String>] human-readable validation error messages: empty
      #   means `data` conforms.
      def errors_for(relative_path, data)
        schemer = JSONSchemer.schema(load(relative_path), ref_resolver: method(:resolve_ref))
        schemer.validate(data).map { |error| JSONSchemer::Errors.pretty(error) }
      end

      def valid?(relative_path, data)
        errors_for(relative_path, data).empty?
      end

      # Method names declared by a vendored OpenRPC document, e.g.
      # "services/shopping/mcp.openrpc.json" -> %w[create_checkout get_cart ...].
      def method_names(relative_path)
        load(relative_path).fetch("methods").map { |m| m.fetch("name") }
      end

      private

      def resolve_ref(uri)
        relative_path = uri.to_s.delete_prefix(@base_url).sub(/#.*/, "")
        load(relative_path)
      end

      def load(relative_path)
        JSON.parse(File.read(File.join(@base_dir, relative_path)))
      end
    end
  end
end

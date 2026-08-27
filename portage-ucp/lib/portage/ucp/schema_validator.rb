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
      #   the vendored path under schemas/<version>/. A path with a
      #   `#/$defs/...` fragment (e.g.
      #   "schemas/shopping/catalog_search.json#/$defs/search_response")
      #   validates against that named subschema instead of the document
      #   root — for schemas like catalog_search.json/catalog_lookup.json
      #   that define several request/response shapes as siblings under
      #   $defs rather than being one schema per file.
      # @return [Array<String>] human-readable validation error messages: empty
      #   means `data` conforms.
      def errors_for(relative_path, data)
        schemer = JSONSchemer.schema(schema_for(relative_path), ref_resolver: method(:resolve_ref))
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

      # A bare path loads and validates against the document root, same as
      # before. A path carrying a fragment becomes a single-$ref schema
      # pointing at that fragment, resolved the same way any other
      # cross-document $ref in these vendored schemas is (via #resolve_ref) —
      # $defs entries can themselves $ref sibling $defs by a local "#/..."
      # pointer (catalog_lookup.json's get_product_response -> #/$defs/
      # detail_product being one), so the fragment must be resolved by the
      # schema library against the whole loaded document, not sliced out of
      # it here.
      def schema_for(relative_path)
        return load(relative_path) unless relative_path.include?("#")

        { "$ref" => "#{@base_url}#{relative_path}" }
      end

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

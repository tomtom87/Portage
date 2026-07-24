module UcpMcp
  module Shopify
    class Error < StandardError; end

    # Raised when a GraphQL response carries top-level `errors` (malformed
    # query, throttled, auth rejected) — distinct from a mutation's
    # `userErrors`, which is a well-formed response describing a business
    # rejection (e.g. "line item not found").
    class GraphqlError < Error
      def initialize(errors)
        super(errors.map { |e| e["message"] }.join("; "))
      end
    end

    # Raised when a mutation's `userErrors` array is non-empty.
    class UserError < Error
      def initialize(field, errors)
        super("#{field} userErrors: #{errors.map { |e| e['message'] }.join('; ')}")
      end
    end
  end
end

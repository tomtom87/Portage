module Portage
  module Ucp
    module Shopify
      # Shopify-specific config, deliberately separate from core's own
      # Portage::Ucp::Configuration (registry/authenticator/rate_limiter/...,
      # already adapter-agnostic — see portage-ucp/lib/portage/ucp/configuration.rb).
      # `Portage::Ucp::Shopify.configuration.metadata_fields` living on this
      # singleton instead is what keeps Mapper's "nothing Shopify-shaped leaks
      # past this file" posture intact: a Wix/WooCommerce consumer configuring
      # their own adapter never sees Shopify's metafield config surface.
      class Configuration
        # Shopify caps `metafields(identifiers:)` at 250 identifiers per call
        # (design-log §20). Enforced here rather than left to a confusing
        # GraphQL cost-limit rejection from Shopify itself.
        MAX_METAFIELD_IDENTIFIERS = 250

        class InvalidMetadataField < ArgumentError; end

        def initialize
          @product_metadata_fields = []
          @variant_metadata_fields = []
        end

        # Registers a merchant-defined metafield as a Product/Variant#metadata
        # entry. `metafield:` is "namespace.key" (Shopify's own addressing,
        # e.g. "custom.color_code"). `scope:` picks which GraphQL field
        # (Product#metafields vs. ProductVariant#metafields — separate fields,
        # separate cost, per Shopify's Admin API) the identifier is fetched
        # through, since a real catalog needs both (color_hex naturally varies
        # per variant, fabric_content is usually product-wide).
        def metadata_field(key, metafield:, scope: :product)
          namespace, metafield_key = metafield.split(".", 2)
          unless metafield_key
            raise InvalidMetadataField, "metafield: must be \"namespace.key\", got #{metafield.inspect}"
          end

          fields = fields_for(scope)
          if fields.size >= MAX_METAFIELD_IDENTIFIERS
            raise InvalidMetadataField,
                  "#{scope} metadata_fields already at Shopify's #{MAX_METAFIELD_IDENTIFIERS}-identifier " \
                  "metafields(identifiers:) cap — drop one before adding #{key.inspect}"
          end

          fields << { key: key.to_s, namespace: namespace, metafield_key: metafield_key }
        end

        # Read by Queries (to build the metafields fragment) and Mapper (to
        # know which response entry maps to which UCP key) — both index by
        # scope, not by name, so this is the one shared accessor.
        def fields_for(scope)
          case scope
          when :product then @product_metadata_fields
          when :variant then @variant_metadata_fields
          else raise InvalidMetadataField, "scope: must be :product or :variant, got #{scope.inspect}"
          end
        end
      end

      class << self
        def configuration
          @configuration ||= Configuration.new
        end

        def configure
          yield configuration
        end
      end
    end
  end
end

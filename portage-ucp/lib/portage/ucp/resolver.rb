module Portage
  module Ucp
    # Shared platform-detection + adapter-building logic for anything that
    # needs to go from "a URL" to "a live Adapter for whatever commerce
    # platform that URL runs on" — originally `Check`-only, now also used by
    # `portage buy`'s adapter-fallback step. Neither caller should duplicate
    # the platform table; both go through here.
    class Resolver
      Platform = Struct.new(:name, :gem, :require_path, :namespace, :markers, :env, :required, :build_client,
                            :build_adapter, keyword_init: true)

      # One entry per adapter gem: how to recognize the platform from its
      # homepage, which env vars its Client/Adapter need (mirroring each
      # gem's exe/, see their READMEs), and how to build a live instance from
      # those env vars.
      PLATFORMS = [
        Platform.new(
          name: "Shopify", gem: "portage-ucp-shopify", require_path: "portage/ucp/shopify", namespace: "Shopify",
          markers: [/cdn\.shopify\.com/i, /Shopify\.theme/i, /\.myshopify\.com/i],
          env: { shop_domain: "SHOPIFY_SHOP_DOMAIN", admin_access_token: "SHOPIFY_ADMIN_ACCESS_TOKEN",
                 storefront_access_token: "SHOPIFY_STOREFRONT_ACCESS_TOKEN" },
          required: %i[shop_domain],
          build_client: lambda { |ns, env|
            ns::Client.new(shop_domain: env.fetch(:shop_domain), admin_access_token: env[:admin_access_token],
                           storefront_access_token: env[:storefront_access_token])
          },
          build_adapter: ->(ns, client, _env) { ns::Adapter.new(client: client) }
        ),
        Platform.new(
          name: "Wix", gem: "portage-ucp-wix", require_path: "portage/ucp/wix", namespace: "Wix",
          markers: [/static\.parastorage\.com/i, /wixstatic\.com/i, /X-Wix-Request-Id/i],
          env: { access_token: "WIX_ACCESS_TOKEN" },
          required: %i[access_token],
          build_client: ->(ns, env) { ns::Client.new(access_token: env.fetch(:access_token)) },
          build_adapter: ->(ns, client, _env) { ns::Adapter.new(client: client) }
        ),
        Platform.new(
          name: "WooCommerce", gem: "portage-ucp-woocommerce", require_path: "portage/ucp/woocommerce",
          namespace: "WooCommerce",
          markers: [/woocommerce/i, %r{wp-content/plugins/woocommerce}i],
          env: { site_url: "WOOCOMMERCE_SITE_URL", consumer_key: "WOOCOMMERCE_CONSUMER_KEY",
                 consumer_secret: "WOOCOMMERCE_CONSUMER_SECRET", currency: "WOOCOMMERCE_CURRENCY" },
          required: %i[site_url consumer_key consumer_secret],
          build_client: lambda { |ns, env|
            ns::Client.new(site_url: env.fetch(:site_url), consumer_key: env.fetch(:consumer_key),
                           consumer_secret: env.fetch(:consumer_secret))
          },
          build_adapter: lambda { |ns, client, env|
            ns::Adapter.new(client: client, site_url: env.fetch(:site_url), currency: env.fetch(:currency, "USD"))
          }
        ),
        Platform.new(
          name: "BigCommerce", gem: "portage-ucp-bigcommerce", require_path: "portage/ucp/bigcommerce",
          namespace: "BigCommerce",
          markers: [/cdn11\.bigcommerce\.com/i, /bigcommerce/i],
          env: { store_hash: "BIGCOMMERCE_STORE_HASH", client_id: "BIGCOMMERCE_CLIENT_ID",
                 access_token: "BIGCOMMERCE_ACCESS_TOKEN", site_url: "BIGCOMMERCE_SITE_URL",
                 currency: "BIGCOMMERCE_CURRENCY" },
          required: %i[store_hash client_id access_token site_url],
          build_client: lambda { |ns, env|
            ns::Client.new(store_hash: env.fetch(:store_hash), client_id: env.fetch(:client_id),
                           access_token: env.fetch(:access_token))
          },
          build_adapter: lambda { |ns, client, env|
            ns::Adapter.new(client: client, site_url: env.fetch(:site_url), currency: env.fetch(:currency, "USD"))
          }
        ),
        Platform.new(
          name: "Magento", gem: "portage-ucp-magento", require_path: "portage/ucp/magento", namespace: "Magento",
          markers: [/Mage\.Cookies/i, /Magento_/i],
          env: { base_url: "MAGENTO_BASE_URL", admin_token: "MAGENTO_ADMIN_TOKEN", currency: "MAGENTO_CURRENCY" },
          required: %i[base_url],
          build_client: lambda { |ns, env|
            ns::Client.new(base_url: env.fetch(:base_url), admin_token: env[:admin_token])
          },
          build_adapter: lambda { |ns, client, env|
            ns::Adapter.new(client: client, site_url: env.fetch(:base_url), currency: env.fetch(:currency, "USD"))
          }
        ),
        Platform.new(
          name: "Etsy", gem: "portage-ucp-etsy", require_path: "portage/ucp/etsy", namespace: "Etsy",
          markers: [/etsy\.com/i],
          env: { access_token: "ETSY_ACCESS_TOKEN", api_key: "ETSY_API_KEY", shop_id: "ETSY_SHOP_ID" },
          required: %i[access_token api_key shop_id],
          build_client: lambda { |ns, env|
            ns::Client.new(access_token: env.fetch(:access_token), api_key: env.fetch(:api_key))
          },
          build_adapter: ->(ns, client, env) { ns::Adapter.new(client: client, shop_id: env.fetch(:shop_id)) }
        ),
        Platform.new(
          name: "Instagram/Facebook Shops", gem: "portage-ucp-instagram", require_path: "portage/ucp/instagram",
          namespace: "Instagram",
          markers: [%r{instagram\.com/[^/]+/shop}i, %r{facebook\.com/.*/shop}i],
          env: { access_token: "META_ACCESS_TOKEN", catalog_id: "META_CATALOG_ID" },
          required: %i[access_token catalog_id],
          build_client: ->(ns, env) { ns::Client.new(access_token: env.fetch(:access_token)) },
          build_adapter: ->(ns, client, env) { ns::Adapter.new(client: client, catalog_id: env.fetch(:catalog_id)) }
        )
      ].freeze

      # @return [Platform, nil] the first platform whose markers match the
      #   given homepage body/headers, or nil if nothing recognizable was found.
      def self.detect_platform(body, headers)
        haystack = [body, headers.to_a.flatten.join(" ")].compact.join(" ")
        PLATFORMS.find { |platform| platform.markers.any? { |marker| haystack =~ marker } }
      end

      # @return [Hash<Symbol, String, nil>] the platform's env vars read from
      #   the process environment, keyed the same as Platform#env/#required.
      def self.env_for(platform)
        platform.env.transform_values { |var| ENV.fetch(var, nil) }
      end

      # @return [Array<String>] the env var names still missing for this
      #   platform to be usable, or an empty array if all required vars are set.
      def self.missing_env(platform, env)
        platform.required.select { |key| env[key].nil? }.map { |key| platform.env[key] }
      end

      # Builds a live Adapter for the given platform from the given env hash
      # (as returned by .env_for). Raises LoadError if the adapter gem isn't
      # installed — callers decide how to handle that (e.g. Check reports it
      # as a skipped probe rather than crashing).
      # @return [Portage::Ucp::Adapter]
      def self.build_adapter(platform, env)
        require platform.require_path
        namespace = Portage::Ucp.const_get(platform.namespace)
        client = platform.build_client.call(namespace, env)
        platform.build_adapter.call(namespace, client, env)
      end
    end
  end
end

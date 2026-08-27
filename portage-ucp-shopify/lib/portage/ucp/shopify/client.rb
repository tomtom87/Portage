require "net/http"
require "json"

module Portage
  module Ucp
    module Shopify
      # Minimal GraphQL client over Shopify's Admin and Storefront APIs.
      #
      # Deliberately plain Net::HTTP, not the `shopify_api` gem: `shopify_api`
      # requires a global `ShopifyAPI::Context.setup` and session object, which
      # forces every consumer onto its config/session model just to make two
      # GraphQL calls. A generic adapter that any Ruby app can drop in (§4 of
      # the plan) is better served by a client that only needs a shop domain
      # and the two tokens a merchant already has — no framework coupling, and
      # trivially stubbable with WebMock in specs.
      #
      # Admin and Storefront are separate Shopify APIs with separate tokens and
      # separate capabilities (Admin has no "Cart"; Storefront can't look up an
      # arbitrary order). The adapter picks whichever API actually has the
      # data it needs (see Portage::Ucp::Shopify::Adapter).
      class Client
        # Retries a bare THROTTLED GraphQL response or a transport 5xx —
        # safe here because every Adapter mutation calling into this Client
        # is already wrapped in Support::Idempotency#dedup, and every read
        # is naturally idempotent (see Support::Retry's own doc comment).
        include Portage::Ucp::Support::Retry

        DEFAULT_API_VERSION = "2026-04".freeze

        def initialize(shop_domain:, admin_access_token: nil, storefront_access_token: nil,
                       api_version: DEFAULT_API_VERSION)
          @shop_domain = shop_domain
          @admin_access_token = admin_access_token
          @storefront_access_token = storefront_access_token
          @api_version = api_version
        end

        def admin_query(query, variables: {})
          require_token!(@admin_access_token, "admin_access_token")
          with_retry do
            post("/admin/api/#{@api_version}/graphql.json",
                 headers: { "X-Shopify-Access-Token" => @admin_access_token }, query: query, variables: variables)
          end
        end

        def storefront_query(query, variables: {})
          require_token!(@storefront_access_token, "storefront_access_token")
          with_retry do
            post("/api/#{@api_version}/graphql.json",
                 headers: { "X-Shopify-Storefront-Access-Token" => @storefront_access_token },
                 query: query, variables: variables)
          end
        end

        private

        def require_token!(token, name)
          raise ArgumentError, "Portage::Ucp::Shopify::Client requires #{name} for this call" unless token
        end

        # Shopify's GraphQL THROTTLED code has no HTTP status of its own, and
        # a transport 5xx here has no well-formed userErrors/GraphQL body to
        # fall back on — Support::Retry's default `#status`-based check
        # covers neither, so this hands both to it explicitly.
        def retryable_error?(error)
          case error
          when Portage::Ucp::Shopify::ServerError then true
          when Portage::Ucp::Shopify::GraphqlError then error.throttled?
          else super
          end
        end

        def post(path, headers:, query:, variables:)
          uri = URI("https://#{@shop_domain}#{path}")
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          headers.each { |key, value| request[key] = value }
          request.body = JSON.generate({ query: query, variables: variables })

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
          status = response.code.to_i
          raise Portage::Ucp::Shopify::ServerError, status if status >= 500

          body = JSON.parse(response.body)
          raise Portage::Ucp::Shopify::GraphqlError, body["errors"] if body["errors"]

          body["data"]
        end
      end
    end
  end
end

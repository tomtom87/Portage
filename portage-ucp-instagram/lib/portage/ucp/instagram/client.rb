require "net/http"
require "json"

module Portage
  module Ucp
    module Instagram
      # Minimal REST client over Meta's Graph API
      # (`graph.facebook.com/{api_version}`), used for both Instagram and
      # Facebook Shops — they share one Commerce Catalog underneath.
      #
      # Deliberately plain Net::HTTP, not the `koala`/`facebook-ads-sdk`
      # gems — a generic adapter that any Ruby app can drop in only needs a
      # base URL and a bearer token, trivially stubbable with WebMock.
      class Client
        include Portage::Ucp::Support::HttpClient
        # Retries a bare HTTP 429/5xx and Meta's own throttling codes (see
        # ApiError#throttled?) — safe here because #get backs every Adapter
        # read, and the one place it backs a mutation-adjacent flow
        # (Adapter#create_checkout's product fetches) is already reached
        # through Support::Idempotency#dedup, same reasoning as
        # portage-ucp-wix's Client.
        include Portage::Ucp::Support::Retry

        # Verified against Meta's published Graph API version list as of
        # 2026-09-24: v21.0 is still supported (expires 2027-01-21) and its
        # Commerce Catalog fields/endpoints this gem uses (`/products`,
        # `PRODUCT_FIELDS`, `filter`/`paging`) are unchanged through the
        # current v26.0. Deliberately NOT bumped to v26.0 despite it being
        # the latest stable release: v26.0 (July 2026) already blocks the
        # ~47 Commerce Order Management endpoints `Adapter#get_order` reads
        # (order retrieval/line items/payment details), following through at
        # the API level on Meta sunsetting native "Checkout on Instagram/
        # Facebook" for all US merchants back in August 2025 — bumping would
        # break that read immediately rather than extend its runway. That
        # runway is short regardless of version: the same block extends to
        # every supported version, v21.0 included, on 2026-10-27, at which
        # point the endpoint is removed entirely with no replacement. See
        # the README's "Meta is sunsetting native checkout" section.
        DEFAULT_API_VERSION = "v21.0".freeze

        def initialize(access_token:, api_version: DEFAULT_API_VERSION)
          @access_token = access_token
          @api_version = api_version
        end

        # `path` is normally relative (`"/#{catalog_id}/products?..."`), but
        # also accepts an absolute URL as-is — Adapter#search_catalog's
        # pagination follows `paging.next`, which Meta hands back as a
        # complete `https://graph.facebook.com/...` URL, not another
        # relative path to re-prefix.
        def get(path)
          with_retry do
            json_request(Net::HTTP::Get, absolute_url(path),
                         headers: { "Authorization" => "Bearer #{@access_token}" })
          end
        end

        private

        def absolute_url(path)
          path.start_with?("http://", "https://") ? path : "https://graph.facebook.com/#{@api_version}#{path}"
        end

        def api_error_class = Portage::Ucp::Instagram::ApiError

        # Support::Retry's default only understands a `status` of 429/5xx;
        # Meta's own throttling codes (4/17/32/613) arrive as a bare HTTP
        # 400, and a code-190 TokenExpiredError must never retry regardless
        # of its status — see errors.rb for both.
        def retryable_error?(error)
          case error
          when Portage::Ucp::Instagram::TokenExpiredError then false
          when Portage::Ucp::Instagram::ApiError then error.throttled?
          else super
          end
        end
      end
    end
  end
end

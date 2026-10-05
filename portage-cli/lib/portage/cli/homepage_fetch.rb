require "net/http"
require "uri"
require "portage/ucp/support/connection"
require_relative "user_agent"

module Portage
  module Cli
    # Shared "fetch this store's homepage, for platform sniffing" logic —
    # originally private to Buy (#fetch_homepage), extracted so
    # HandoffReconciler's own adapter-fallback reconnect (see
    # docs/plans/handoff-reconcile.md, "Reconciling needs the store again")
    # doesn't duplicate it.
    module HomepageFetch
      REDIRECT_LIMIT = 5

      # @param route [Symbol] Support::Connection route for every hop,
      #   redirects included (:store, or :payment for PaymentMethods).
      # @return [Array(String, Hash), Array(nil, Hash)] the body and response
      #   headers, or [nil, {}] on any failure/redirect exhaustion — same
      #   "no automated path, not a crash" posture as the rest of the buy
      #   flow.
      def self.call(uri, limit: REDIRECT_LIMIT, route: :store)
        return [nil, {}] if limit.zero?

        response = Portage::Ucp::Support::Connection.start(uri, route: route, open_timeout: 5,
                                                                read_timeout: 5) do |http|
          http.get(uri.request_uri, UserAgent.headers)
        end

        case response
        when Net::HTTPRedirection
          call(URI.join(uri, response["location"]), limit: limit - 1, route: route)
        when Net::HTTPSuccess
          [response.body, response.to_hash]
        else
          [nil, {}]
        end
      rescue StandardError
        [nil, {}]
      end
    end
  end
end

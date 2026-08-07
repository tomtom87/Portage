require "net/http"
require "uri"
require "json"
require "portage/ucp"
require "portage/ucp/client"

module Portage
  module Cli
    # `portage buy <url>` — the single entrypoint for "get this thing bought",
    # regardless of whether the target store speaks native UCP, only offers a
    # catalog, or doesn't speak UCP at all but happens to run a platform we
    # have an adapter (and this process's own credentials) for.
    #
    # Never tries to buy as an anonymous shopper via scraping/session-hijacking
    # (ToS violation, explicitly ruled out), and never falls back to an
    # adapter unless this process already has that platform's own env vars
    # set — i.e. it's your own store, or one you're integrated with, never a
    # stranger's. See docs/design-log.md for the reasoning behind it.
    class Buy
      CART_CAP = "dev.ucp.shopping.cart".freeze
      CHECKOUT_CAP = "dev.ucp.shopping.checkout".freeze
      REDIRECT_LIMIT = 5

      def initialize(url:, query:, qty: 1, payment_token: nil, yes: false, dry_run: false)
        raw = url.to_s.strip
        raw = "https://#{raw}" unless raw =~ %r{\Ahttps?://}i
        @uri = URI.parse(raw)
        @query = query
        @qty = qty
        @payment_token = payment_token
        @yes = yes
        @dry_run = dry_run
      end

      def call
        session = discover(@uri)
        return native_flow(session) if session

        body, headers = fetch_homepage(@uri)

        linked = manifest_link(body)
        if linked
          session = discover(linked)
          return native_flow(session) if session
        end

        platform = Portage::Ucp::Resolver.detect_platform(body, headers)
        adapter_flow(platform) || dead_end
      end

      private

      # --- Step 1: native UCP manifest ---

      def discover(url)
        Portage::Ucp::Client.discover(url.to_s)
      rescue Portage::Ucp::Client::DiscoveryError
        nil
      end

      def native_flow(session)
        if session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)
          full_buy(session, source: "native_ucp")
        else
          catalog_only(session)
        end
      end

      def catalog_only(session)
        products = safe_search(session)
        report = build_report(
          source: "native_ucp", browse: true, checkout: false, products: products,
          message: "I can browse this store but can't check out via UCP yet."
        )
        merge_adapter_checkout_fallback(report)
      end

      # No manifest advertised checkout — see whether a platform adapter can
      # still cover it (fetches the homepage fresh; the "fetch once" rule in
      # the design only covers the "no manifest at all" branch below, since
      # this is a genuinely separate path).
      def merge_adapter_checkout_fallback(report)
        body, headers = fetch_homepage(@uri)
        platform = Portage::Ucp::Resolver.detect_platform(body, headers)
        fallback = platform && adapter_flow(platform)
        return report unless fallback && fallback[:checkout]

        report.merge(source: fallback[:source], checkout: true, checkout_url: fallback[:checkout_url])
      end

      # --- Step 1 fallback: alternate manifest pointer in <head> ---

      def manifest_link(body)
        return nil unless body

        match = body.match(/<link[^>]+rel=["']ucp["'][^>]+href=["']([^"']+)["']/i) ||
                body.match(/<link[^>]+href=["']([^"']+)["'][^>]+rel=["']ucp["']/i)
        match && URI.join(@uri, match[1])
      end

      # --- Step 2/3: platform detection + adapter fallback ---

      def adapter_flow(platform)
        return nil unless platform

        env = Portage::Ucp::Resolver.env_for(platform)
        return nil if Portage::Ucp::Resolver.missing_env(platform, env).any?

        adapter = Portage::Ucp::Resolver.build_adapter(platform, env)
        if adapter_supports_checkout?(adapter)
          full_buy(client_for(adapter), source: "adapter:#{platform.name}")
        else
          catalog_only_adapter(adapter, platform)
        end
      rescue LoadError, StandardError
        nil
      end

      def adapter_supports_checkout?(adapter)
        Portage::Ucp::Capabilities::CART.advertised_for?(adapter) &&
          Portage::Ucp::Capabilities::CHECKOUT.advertised_for?(adapter)
      end

      def client_for(adapter)
        Portage::Ucp::Client.for_adapter(adapter, authenticator: PermissiveAuthenticator.new)
      end

      def catalog_only_adapter(adapter, platform)
        products = Array(adapter.search_catalog(query: @query, limit: 10))
        checkout = redirect_checkout(adapter, products)
        build_report(
          source: "adapter:#{platform.name}", browse: true, checkout: !!checkout,
          products: products, checkout_url: checkout && checkout.links.first&.url,
          message: "Found it on #{platform.name}, but checkout there isn't a live UCP transaction — " \
                   "#{checkout ? 'follow the link to buy it yourself.' : 'no checkout path at all.'}"
        )
      end

      def redirect_checkout(adapter, products)
        return nil if products.empty? || !Portage::Ucp::Capabilities::CHECKOUT.advertised_for?(adapter)

        adapter.create_checkout(line_items: [{ product_id: products.first.id, quantity: @qty }],
                                idempotency_key: "portage-buy-#{products.first.id}")
      rescue StandardError
        nil
      end

      # --- The actual buy, shared by native and adapter-loopback sources ---

      def full_buy(session, source:)
        products = safe_search(session)
        product = products.first
        unless product
          return build_report(source: source, browse: true, checkout: true, products: products,
                              message: "No product matched \"#{@query}\".")
        end

        checkout = session.create_checkout(line_items: [{ product_id: product_id_of(product), quantity: @qty }])
        finish_checkout(session, source, products, checkout)
      end

      # search_catalog's results are raw Portage::Ucp::Product structs over
      # the loopback transport (Product has no #to_wire_h, see
      # Dispatcher#wrap) but string-keyed wire hashes over stdio/HTTP (the
      # `mcp` gem's client parses real JSON) — handle both.
      def product_id_of(product)
        product.respond_to?(:id) ? product.id : product["id"]
      end

      def finish_checkout(session, source, products, checkout)
        status = checkout["status"]
        return escalation_report(source, products, checkout) if status == "requires_escalation"
        return dry_run_report(source, products, checkout) if @dry_run
        return confirmation_needed_report(source, products, checkout) unless confirmed?

        complete(session, source, products, checkout)
      end

      def complete(session, source, products, checkout)
        unless @payment_token
          return checkout_report(source, products, checkout,
                                 message: "No --payment-token given — can't complete the purchase.")
        end

        completed = session.complete_checkout(checkout_id: checkout["id"], payment_token: @payment_token)
        checkout_report(source, products, completed, message: "Purchased.")
      end

      def confirmed?
        @yes
      end

      def escalation_report(source, products, checkout)
        checkout_report(source, products, checkout,
                        checkout_url: checkout["links"]&.find { |l| l["url"] }&.fetch("url", nil),
                        message: "Checkout requires buyer escalation — visit the link to complete it.")
      end

      def dry_run_report(source, products, checkout)
        checkout_report(source, products, checkout, message: "Dry run — checkout created but not completed.")
      end

      def confirmation_needed_report(source, products, checkout)
        checkout_report(source, products, checkout, message: "Checkout ready — pass --yes to confirm the purchase.")
      end

      # Flattens the parts of a Checkout wire hash a CLI caller actually
      # wants to see (id/status/totals) onto the report, rather than nesting
      # the raw hash under a key that'd collide with the boolean `checkout:`
      # field the output struct already reserves (§ output shape).
      def checkout_report(source, products, checkout, message:, checkout_url: nil)
        build_report(source: source, browse: true, checkout: true, products: products, message: message,
                     checkout_url: checkout_url, checkout_id: checkout["id"], checkout_status: checkout["status"],
                     totals: checkout["totals"])
      end

      def safe_search(session)
        Array(session.search_catalog(query: @query, limit: 10))
      end

      # --- Homepage fetch (used by both the manifest-not-found path and the
      # catalog-only-native adapter-checkout-fallback path) ---

      def fetch_homepage(uri, limit = REDIRECT_LIMIT)
        return [nil, {}] if limit.zero?

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 5, read_timeout: 5) do |http|
          http.get(uri.request_uri, { "User-Agent" => "portage-buy" })
        end

        case response
        when Net::HTTPRedirection
          fetch_homepage(URI.join(uri, response["location"]), limit - 1)
        when Net::HTTPSuccess
          [response.body, response.to_hash]
        else
          [nil, {}]
        end
      rescue StandardError
        [nil, {}]
      end

      def dead_end
        build_report(source: "none", browse: false, checkout: false,
                     message: "No automated path — visit #{@uri} yourself.")
      end

      def build_report(**fields)
        { url: @uri.to_s, checkout_url: nil, products: [] }.merge(fields)
      end

      # Loopback buy against your own store needs *some* authenticator (§9
      # rejects anonymous mutation by default) — since this process already
      # has this platform's own credentials (that's the gate to even reach
      # here), authenticating this local CLI session is reasonable.
      class PermissiveAuthenticator < Portage::Ucp::Authenticator
        def call(_server_context) = :local_cli
      end
    end
  end
end

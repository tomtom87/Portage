require "net/http"
require "uri"
require "json"
require "portage/ucp"
require "portage/ucp/client"
require "portage/ucp/journal"
require_relative "payment_methods"
require_relative "checkout_handoff"
require_relative "notifier"

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

      # @param product_id [String, nil] buy exactly this product instead of
      #   whatever the catalog search happens to rank first — how `portage
      #   find` hands a picked offer over without the ranking being guessed
      #   twice.
      # @param auto_open [Boolean, nil] per-invocation override for whether a
      #   dead-end checkout_url auto-opens in the shopper's browser — nil
      #   (the default) defers to PORTAGE_AUTO_OPEN_CHECKOUT / config.json
      #   (see CheckoutHandoff).
      # @param notify_webhook [String, nil] per-invocation override for the
      #   webhook URL a dead-end checkout_url is POSTed to — nil (the
      #   default) defers to PORTAGE_NOTIFY_WEBHOOK_URL / config.json (see
      #   Notifier).
      def initialize(url:, query:, qty: 1, payment_token: nil, yes: false, dry_run: false, product_id: nil,
                     auto_open: nil, notify_webhook: nil)
        raw = url.to_s.strip
        raw = "https://#{raw}" unless raw =~ %r{\Ahttps?://}i
        @uri = URI.parse(raw)
        @query = query
        @qty = qty
        @payment_token = payment_token
        @yes = yes
        @dry_run = dry_run
        @product_id = product_id
        @auto_open = auto_open
        @notify_webhook = notify_webhook
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
      rescue Portage::Ucp::Client::ManifestShapeError => e
        # The store *is* running UCP — this client just couldn't parse its
        # manifest. Distinct from a genuine 404/unreachable host below:
        # falling through silently there would hide a bug in this gem behind
        # the same "no automated path" message a store with no UCP support
        # gets, so this warns instead.
        warn "portage: #{url} serves a UCP manifest this client couldn't parse (#{e.message})"
        nil
      rescue Portage::Ucp::Client::DiscoveryError
        nil
      end

      def native_flow(session)
        if session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)
          full_buy(session, source: "native_ucp")
        else
          catalog_only(session)
        end
      rescue Portage::Ucp::Client::MissingAgentProfileError, Portage::Ucp::Client::UnsupportedWireShapeError,
             Portage::Ucp::Client::ServerError, MCP::Client::RequestHandlerError => e
        native_flow_error_report(e)
      end

      def native_flow_error_report(error)
        case error
        when Portage::Ucp::Client::MissingAgentProfileError
          build_report(source: "native_ucp", browse: false, checkout: false,
                       message: "Set PORTAGE_AGENT_PROFILE to a URL that describes this agent — " \
                                "#{@uri} verifies it before answering any UCP call.")
        when Portage::Ucp::Client::UnsupportedWireShapeError
          build_report(source: "native_ucp", browse: true, checkout: false,
                       message: "Can't complete checkout on #{@uri} yet: #{error.message}")
        when Portage::Ucp::Client::ServerError
          server_error_report(error)
        else
          # MCP::Client::RequestHandlerError doesn't retain the server's JSON
          # error body on this path, so this can't quote the server's own
          # explanation — a common cause is PORTAGE_AGENT_PROFILE not
          # pointing at a real, JSON agent-profile document the store's UCP
          # endpoint accepts.
          build_report(source: "native_ucp", browse: false, checkout: false,
                       message: "#{@uri} rejected the request (#{error.message}) — if PORTAGE_AGENT_PROFILE " \
                                "is set, check it points at a real agent-profile document the store accepts.")
        end
      end

      # A store refusing a cart/checkout call on its own terms — out of stock,
      # a line it won't accept, a cart that expired — is an answer, not a
      # crash. This used to escape `#call` as an unhandled ServerError,
      # printing a Ruby backtrace whose "message" was the server's entire
      # several-kilobyte `ucp` envelope (confirmed live 2026-09-22: a
      # genuinely sold-out variant on a Shopify store). Report the server's
      # own sentence instead, and hand back the `continue_url` it supplied so
      # the shopper has somewhere to go — same posture as
      # #escalation_report/#permission_denied_report.
      #
      # Deliberately not routed through #hand_off: that fires the auto-open
      # and webhook side effects, which belong to a checkout this agent
      # actually built. There's no checkout here — the call that failed is
      # what would have created one.
      def server_error_report(error)
        url = error.continue_url
        build_report(
          source: "native_ucp", browse: true, checkout: false, checkout_url: url,
          message: "#{@uri} couldn't complete this: #{error.summary}#{url && " — finish it at #{url}"}"
        )
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

        begin
          adapter = Portage::Ucp::Resolver.build_adapter(platform, env)
        rescue LoadError
          return nil
        end

        run_adapter_flow(adapter, platform)
      end

      # Once the adapter gem is installed and the adapter itself is live, a
      # `StandardError` it raises is a real, actionable failure (e.g. "no
      # payment_method configured") — surface it instead of falling through
      # to `dead_end`'s generic "visit it yourself" message, which would hide
      # it identically to "there's no adapter for this platform at all".
      def run_adapter_flow(adapter, platform)
        if adapter_supports_checkout?(adapter)
          full_buy(client_for(adapter), source: "adapter:#{platform.name}", fulfillment_adapter: adapter)
        else
          catalog_only_adapter(adapter, platform)
        end
      rescue StandardError => e
        build_report(source: "adapter:#{platform.name}", browse: false, checkout: false,
                     message: "#{platform.name} adapter error: #{e.message}")
      end

      def adapter_supports_checkout?(adapter)
        Portage::Ucp::Capabilities::CART.advertised_for?(adapter) &&
          Portage::Ucp::Capabilities::CHECKOUT.advertised_for?(adapter)
      end

      # `journal:` closes design-log §37's named gap — `Mcp::Server.build`
      # (and the `Loopback`/`Client.for_adapter` it sits behind) now forward
      # a `journal:` kwarg straight to `Dispatcher`, but nothing on this own-
      # store loopback path ever passed one, so `portage buy` against your
      # own store settled real transactions/orders while leaving the journal
      # `nil`. `PurchaseJournal.new`'s own default (`FileStore.new`) is
      # `~/.portage/journal.jsonl` — the same "real file-backed default"
      # posture `transaction_log:`/`order_ledger:` already get from
      # `Dispatcher#initialize`.
      def client_for(adapter)
        Portage::Ucp::Client.for_adapter(adapter, authenticator: PermissiveAuthenticator.new,
                                                  journal: Portage::Ucp::Journal::PurchaseJournal.new)
      end

      def catalog_only_adapter(adapter, platform)
        products = CatalogProducts.from(adapter.search_catalog(query: @query, limit: 10))
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

        item_id = products.first.variants&.first&.id || products.first.id
        adapter.create_checkout(line_items: [{ product_id: item_id, quantity: @qty }],
                                idempotency_key: "portage-buy-#{item_id}")
      rescue StandardError
        nil
      end

      # --- The actual buy, shared by native and adapter-loopback sources ---

      # `fulfillment_adapter:` is only ever set by #adapter_flow (the
      # own-store loopback path) — #native_flow has no raw Adapter object to
      # inspect for `fulfillment_supported?`, just a Session talking to a
      # remote store, so shipping-address/rate selection stays loopback-only
      # for now rather than guessing at a wire shape no real UCP server has
      # confirmed (see docs/design-log.md).
      def full_buy(session, source:, fulfillment_adapter: nil)
        products = safe_search(session)
        product = select_product(products)
        unless product
          return build_report(source: source, browse: true, checkout: true, products: products,
                              message: no_match_message)
        end

        checkout = session.create_checkout(line_items: [{ product_id: line_item_id_of(product), quantity: @qty }],
                                           fulfillment: requested_fulfillment(fulfillment_adapter),
                                           context: buyer_context, meta: agent_meta)
        checkout = select_cheapest_shipping(session, checkout) if fulfillment_adapter
        finish_checkout(session, source, products, checkout)
      end

      # Submits PORTAGE_SHIP_* (see Portage::Cli::ShippingProfile) as the
      # checkout's shipping destination, but only when the adapter actually
      # advertises dev.ucp.shopping.fulfillment — an adapter that doesn't
      # override #fulfillment_supported? would just ignore the param anyway
      # (Adapter#create_checkout's default), but there's no point building it
      # at all in that case.
      def requested_fulfillment(adapter)
        return nil unless adapter && Portage::Ucp::Capabilities::FULFILLMENT.advertised_for?(adapter)

        address = Portage::Cli::ShippingProfile.from_env
        return nil unless address

        Portage::Ucp::CheckoutFulfillment.new(
          shipping_methods: [Portage::Ucp::FulfillmentMethod.new(
            id: "requested", type: "shipping", line_item_ids: [],
            destinations: [Portage::Ucp::ShippingDestination.new(id: "current", address: address)]
          )]
        )
      end

      # Once the merchant has priced options against the submitted address,
      # auto-picks the cheapest unselected option per fulfillment group and
      # submits it via #update_checkout — no interactive rate picker; a CLI
      # driving a single automated purchase needs a deterministic default,
      # not a prompt. A checkout with no fulfillment groups at all (no
      # address was submitted, or the merchant hasn't priced anything yet)
      # passes through unchanged.
      def select_cheapest_shipping(session, checkout)
        groups = checkout.dig("fulfillment", "methods", 0, "groups") || []
        selections = groups.filter_map { |g| cheapest_option_selection(g) }
        return checkout if selections.empty?

        session.update_checkout(
          checkout_id: checkout["id"], line_items: current_line_items(checkout),
          fulfillment: Portage::Ucp::CheckoutFulfillment.new(
            shipping_methods: [Portage::Ucp::FulfillmentMethod.new(id: "requested", type: "shipping",
                                                                   line_item_ids: [], groups: selections)]
          )
        )
      end

      def cheapest_option_selection(group)
        return nil if group["selected_option_id"] || (group["options"] || []).empty?

        cheapest = group["options"].min_by { |o| o.dig("totals", 0, "amount") || 0 }
        Portage::Ucp::FulfillmentGroup.new(id: group["id"], line_item_ids: group["line_item_ids"],
                                           selected_option_id: cheapest["id"])
      end

      # Checkout's line_items are response-shaped ({item: {id, ...}, ...});
      # #update_checkout takes request-shaped hashes, same asymmetry
      # #product_id_of already handles for search results.
      def current_line_items(checkout)
        checkout["line_items"].map { |li| { product_id: li.dig("item", "id"), quantity: li["quantity"] } }
      end

      def no_match_message
        return "No product matched \"#{@query}\"." unless @product_id

        "Product #{@product_id} isn't in this store's results for \"#{@query}\"."
      end

      # With a --product-id, that exact product or nothing: falling back to the
      # top search hit when the requested id isn't in the results would buy
      # something the caller never chose.
      def select_product(products)
        return products.first unless @product_id

        products.find { |product| product_id_of(product) == @product_id }
      end

      # #select_product only ever sees products from #safe_search, which reads
      # through a Session — native remote or the own-store loopback session
      # built via Client.for_adapter alike — so Dispatcher#wrap has already
      # called #to_wire_h on every result; a string-keyed wire hash either
      # way, never a raw Portage::Ucp::Product struct.
      def product_id_of(product)
        product["id"]
      end

      # `create_checkout`'s `line_items[].product_id` is the conformance
      # kit's overloaded name (portage-ucp/lib/portage/ucp/rspec.rb) for
      # "whatever id this adapter's cart actually takes" — for a backend
      # where a product's variants have their own id (confirmed live on
      # Shopify: a ProductVariant GID, distinct from the parent Product
      # GID), that's the first/default variant, not the catalog id
      # #product_id_of returns for display/--product-id matching. A
      # product with no variants (or a backend that doesn't distinguish
      # the two) falls back to the product id unchanged (see
      # docs/design-log.md §41).
      def line_item_id_of(product)
        product["variants"]&.first&.dig("id") || product_id_of(product)
      end

      def finish_checkout(session, source, products, checkout)
        status = checkout["status"]
        return escalation_report(source, products, checkout) if status == "requires_escalation"
        return dry_run_report(source, products, checkout) if @dry_run
        return confirmation_needed_report(source, products, checkout) unless confirmed?

        complete(session, source, products, checkout)
      end

      def complete(session, source, products, checkout)
        @payment_token ||= PaymentMethods.default
        unless @payment_token
          url = checkout_url_of(checkout)
          return checkout_report(
            source, products, checkout,
            checkout_url: url, handoff: hand_off(checkout, reason: "no_payment_token", source: source),
            message: "No --payment-token given, and no default payment method on file — run " \
                     "`portage payment enroll` or pass --payment-token, or visit the link to " \
                     "finish this checkout yourself."
          )
        end

        completed = session.complete_checkout(checkout_id: checkout["id"], payment_token: @payment_token)
        checkout_report(source, products, completed, message: "Purchased.")
      rescue Portage::Ucp::Client::PaymentPermissionError
        permission_denied_report(source, products, checkout)
      end

      # Same posture as #escalation_report: a completion this agent isn't
      # granted permission for is a normal outcome, not a failure — the
      # shopper finishes on the merchant's own continue_url/checkout link,
      # same hand-off requires_escalation already uses (see
      # Client::PaymentPermissionError).
      def permission_denied_report(source, products, checkout)
        url = checkout_url_of(checkout)
        checkout_report(
          source, products, checkout,
          checkout_url: url, handoff: hand_off(checkout, reason: "permission_denied", source: source),
          message: "This agent isn't yet granted permission to complete checkout on this store — " \
                   "visit the link to finish it yourself."
        )
      end

      # Never fires on --dry-run (a dry run creates a real checkout but never
      # attempts completion — auto-opening/notifying over a preview run would
      # be actively wrong), and never fires without a checkout_url to hand
      # off. Best-effort: a failed open or failed webhook POST never raises
      # out of #call (see CheckoutHandoff, Notifier), so the checkout itself
      # — created, or correctly escalated — stays the outcome of record
      # either way.
      def hand_off(checkout, reason:, source:)
        url = checkout_url_of(checkout)
        return nil if @dry_run || url.nil?

        opened = CheckoutHandoff.new(auto_open: @auto_open).call(url)
        error = notifier.call(event: "checkout_handoff", reason: reason, checkout_url: url,
                              checkout_id: checkout["id"], source: source, totals: checkout["totals"])
        { url: url, opened: opened, notified: notifier.enabled? && error.nil?, notify_error: error }
      end

      def notifier
        @notifier ||= Notifier.new(webhook_url: @notify_webhook)
      end

      # Every checkout that can't be finished by this process — no
      # permission, no token, or an explicit requires_escalation — hands off
      # through the same `links` field rather than leaving the shopper at a
      # dead end. `find { |l| l["url"] }` rather than a `"type" == "checkout"`
      # match since not every backend's link entries name a type.
      def checkout_url_of(checkout)
        checkout["links"]&.find { |l| l["url"] }&.fetch("url", nil)
      end

      def confirmed?
        @yes
      end

      def escalation_report(source, products, checkout)
        url = checkout_url_of(checkout)
        checkout_report(
          source, products, checkout,
          checkout_url: url, handoff: hand_off(checkout, reason: "requires_escalation", source: source),
          message: "Checkout requires buyer escalation — visit the link to complete it."
        )
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
      def checkout_report(source, products, checkout, message:, checkout_url: nil, handoff: nil)
        build_report(source: source, browse: true, checkout: true, products: products, message: message,
                     checkout_url: checkout_url, checkout_id: checkout["id"], checkout_status: checkout["status"],
                     totals: checkout["totals"], handoff: handoff)
      end

      def safe_search(session)
        CatalogProducts.from(session.search_catalog(query: @query, limit: 10, context: buyer_context,
                                                    meta: agent_meta))
      end

      # A real store resolves which market — and so which inventory and
      # prices — a call is scoped to from this (see
      # Portage::Cli::BuyerContext). The loopback/stdio transports drop it.
      def buyer_context
        @buyer_context ||= BuyerContext.from_env
      end

      # Real UCP servers fetch this URL to verify the caller's identity
      # before answering any call (see Transports::Http) — the own-store
      # loopback path ignores it harmlessly, so it's cheapest to always pass
      # it rather than branch on which transport `session` happens to be.
      def agent_meta
        { agent_profile: ENV.fetch("PORTAGE_AGENT_PROFILE", nil) }
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

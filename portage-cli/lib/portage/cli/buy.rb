require "net/http"
require "uri"
require "json"
require "portage/ucp"
require "portage/ucp/client"
require "portage/ucp/journal"
require_relative "payment_methods"
require_relative "setting"
require_relative "decisions"
require_relative "confidence_check"
require_relative "checkout_handoff"
require_relative "notifier"
require_relative "user_agent"

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
      # @param confidence_check [ConfidenceCheck, nil] the opt-in confidence
      #   gate in front of an unattended completion. nil (the default) builds
      #   one from PORTAGE_DECISION_BACKEND / PORTAGE_MIN_CONFIDENCE, which is
      #   a no-op when no backend is named.
      # @param transaction_log [Portage::Ucp::Support::TransactionLog, nil]
      #   where a remote purchase is recorded, and what the spend policy's
      #   rolling cap and velocity limit count. nil (the default) is the
      #   real ~/.portage/transactions.json, the file Dispatcher writes for
      #   own-store purchases.
      # @param max_price [Integer, nil] the most one unit may cost, in minor
      #   units (same as Find's). A product priced above it is never picked,
      #   even with a --product-id; one with no price to go on still is, as
      #   in Find, and the checkout's own total then meets the spend policy.
      # rubocop:disable Metrics/ParameterLists -- all keywords; one per flag, plus two injectable collaborators
      def initialize(url:, query:, qty: 1, payment_token: nil, yes: false, dry_run: false, product_id: nil,
                     auto_open: nil, notify_webhook: nil, confidence_check: nil, transaction_log: nil,
                     max_price: nil)
        # rubocop:enable Metrics/ParameterLists
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
        @confidence_check = confidence_check
        @transaction_log = transaction_log
        @max_price = max_price
        @decisions = {}
      end

      # Link `type`s that are never the checkout — see #checkout_url_of.
      POLICY_LINK_TYPES = /policy|policies|terms|contact|privacy|legal|imprint/i

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
        Portage::Ucp::Client.discover(url.to_s, headers: UserAgent.headers)
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
          build_report(source: "native_ucp", outcome: "agent_profile_missing", browse: false, checkout: false,
                       message: "Set PORTAGE_AGENT_PROFILE to a URL that describes this agent — " \
                                "#{@uri} verifies it before answering any UCP call.")
        when Portage::Ucp::Client::UnsupportedWireShapeError
          build_report(source: "native_ucp", outcome: "unsupported_wire_shape", browse: true, checkout: false,
                       message: "Can't complete checkout on #{@uri} yet: #{error.message}")
        when Portage::Ucp::Client::ServerError
          server_error_report(error)
        else
          # MCP::Client::RequestHandlerError doesn't retain the server's JSON
          # error body on this path, so this can't quote the server's own
          # explanation — a common cause is PORTAGE_AGENT_PROFILE not
          # pointing at a real, JSON agent-profile document the store's UCP
          # endpoint accepts.
          build_report(source: "native_ucp", outcome: "request_rejected", browse: false, checkout: false,
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
          source: "native_ucp", outcome: "store_refused", browse: true, checkout: false, checkout_url: url,
          message: "#{@uri} couldn't complete this: #{error.summary}#{url && " — finish it at #{url}"}"
        )
      end

      def catalog_only(session)
        products = safe_search(session)
        report = build_report(
          source: "native_ucp", outcome: "browse_only", browse: true, checkout: false, products: products,
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

        # The original `report[:message]` ("I can browse this store but
        # can't check out via UCP yet.") goes stale the moment `checkout:`
        # flips to true here — leaving it would tell the caller there's no
        # checkout path in the same report that hands them a checkout_url.
        report.merge(source: fallback[:source], checkout: true, checkout_url: fallback[:checkout_url],
                     message: "#{report[:message]} Falling back to #{fallback[:source]} — " \
                              "follow the link to buy it that way instead.")
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
        rescue StandardError => e
          # Distinct from LoadError above: the gem *is* installed and this
          # platform *was* detected, so a raise here is a real config
          # problem (e.g. malformed WOOCOMMERCE_BILLING_ADDRESS JSON) — same
          # "actionable, don't hide it behind dead_end" posture as
          # #run_adapter_flow's own rescue, just one step earlier.
          return build_report(source: "adapter:#{platform.name}", outcome: "adapter_misconfigured", browse: false,
                              checkout: false, message: "#{platform.name} adapter misconfigured: #{e.message}")
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
        # `e.message` is the store's own text where the adapter raised an
        # ApiError (see Support::ApiError#detail) — quoted verbatim, not
        # replaced with a generic message, so the actual cause (a missing
        # param, an out-of-stock line, a bad gateway id) is visible. Always
        # paired with a next action, since "here's an error" alone leaves the
        # caller to guess whether to retry, reconfigure, or give up.
        build_report(source: "adapter:#{platform.name}", outcome: "adapter_error", browse: false, checkout: false,
                     message: "#{platform.name} adapter error: #{e.message} — visit #{@uri} yourself, " \
                              "or fix the adapter's env/config and retry.")
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
          source: "adapter:#{platform.name}", outcome: "browse_only", browse: true, checkout: !!checkout,
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
          return build_report(source: source, outcome: "no_match", browse: true, checkout: true, products: products,
                              message: no_match_message)
        end

        checkout = session.create_checkout(line_items: [{ product_id: line_item_id_of(product), quantity: @qty }],
                                           fulfillment: requested_fulfillment(fulfillment_adapter),
                                           context: buyer_context, meta: agent_meta)
        checkout = select_cheapest_shipping(session, checkout) if fulfillment_adapter

        warnings = reconcile_checkout(product, checkout)
        finish_checkout(session, source, products, checkout, warnings)
      end

      # A store can silently drop the requested line, change its quantity, or
      # price it differently than its own catalog just quoted a moment
      # earlier in #safe_search — none of that raises, since it's a normal
      # (if surprising) checkout response, not a transport error. Buying
      # blind against a mismatch this method could have caught defeats the
      # point of an agent shopping on the buyer's behalf, so this always
      # checks and surfaces what it finds; PORTAGE_ABORT_ON_CHECKOUT_MISMATCH
      # additionally refuses to proceed rather than merely warning.
      def reconcile_checkout(product, checkout)
        item_id = line_item_id_of(product)
        line = Array(checkout["line_items"]).find { |li| li.dig("item", "id") == item_id }
        return ["Store dropped the requested item (#{item_id}) from checkout."] unless line

        warnings = []
        if line["quantity"] != @qty
          warnings << "Store checked out quantity #{line['quantity']}, not the requested #{@qty}."
        end

        expected = expected_unit_price(product, item_id)
        actual = line.dig("item", "price")
        if expected && actual && expected != actual
          warnings << "Store priced the item at #{actual} #{checkout['currency']} minor units per unit, " \
                      "not the catalog's #{expected}."
        end
        warnings
      end

      def expected_unit_price(product, item_id)
        variant = Array(product["variants"]).find { |v| v["id"] == item_id }
        variant&.dig("price", "amount") || product.dig("price_range", "min", "amount")
      end

      def abort_on_mismatch?
        Setting.flag?(env: "PORTAGE_ABORT_ON_CHECKOUT_MISMATCH")
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
        budget = @max_price ? " at or under #{@max_price} minor units" : ""
        return "No product matched \"#{@query}\"#{budget}." unless @product_id

        "Product #{@product_id} isn't in this store's results for \"#{@query}\"#{budget}."
      end

      # With a --product-id, that exact product or nothing: falling back to the
      # top search hit when the requested id isn't in the results would buy
      # something the caller never chose.
      #
      # Without one, the top hit a shopper could actually buy: checking out a
      # sold-out top hit dead-ends on the store's "Sold out" refusal even
      # when an in-stock match sits right below it (confirmed live
      # 2026-09-23 on allbirds.com and billabong.com). Falls back to the top
      # hit when nothing reports stock, so the store still gets to answer.
      #
      # Either way, only among products within --max-price: before it
      # reached here, `buy <url> --max-price` checked out whatever the store
      # ranked first (confirmed live 2026-09-24: a $679.95 board on
      # burton.com under --max-price 600).
      def select_product(products)
        products = products.select { |product| within_max_price?(product) }
        return products.find { |product| available?(product) } || products.first unless @product_id

        products.find { |product| product_id_of(product) == @product_id }
      end

      # Priced the way #reconcile_checkout expects the store to charge: the
      # variant #line_item_id_of would check out, else the product's lowest
      # price.
      def within_max_price?(product)
        return true unless @max_price

        price = expected_unit_price(product, line_item_id_of(product))
        price.nil? || price <= @max_price
      end

      # A product with no variant availability to go on counts as buyable —
      # only an explicit `available: false` on every variant rules it out.
      def available?(product)
        variants = Array(product["variants"])
        variants.empty? || variants.any? { |variant| variant_available?(variant) }
      end

      def variant_available?(variant) = variant.dig("availability", "available") != false

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
      # docs/design-log.md §41). The first in-stock variant wins over the
      # first variant, for the same reason #select_product skips sold-out
      # products (a live Brooklinen sheet set lists its sold-out size first).
      def line_item_id_of(product)
        variants = Array(product["variants"])
        (variants.find { |variant| variant_available?(variant) } || variants.first)&.dig("id") ||
          product_id_of(product)
      end

      def finish_checkout(session, source, products, checkout, warnings = [])
        escalation = decide_escalation(checkout, warnings)
        return escalated_report(source, products, checkout, warnings, escalation) if escalation[:escalate]
        return dry_run_report(source, products, checkout, warnings) if @dry_run
        return confirmation_needed_report(source, products, checkout, warnings) unless confirmed?

        complete(session, source, products, checkout, warnings)
      end

      # Hand off vs. keep going is Decisions.escalation's call
      # (docs/plans/system-one-decision-layer.md § Responsibilities 2): a
      # literal `requires_escalation` status always escalates. A mismatch
      # from #reconcile_checkout escalates only under
      # PORTAGE_ABORT_ON_CHECKOUT_MISMATCH. By default the warnings are
      # surfaced on the report, and the purchase is not stopped for them.
      # The verdict lands on the report's `decisions:`, and the report's
      # `outcome:` names which gate (if any) stopped the purchase.
      def decide_escalation(checkout, warnings)
        verdict = Decisions.escalation(checkout_status: checkout["status"],
                                       warnings: abort_on_mismatch? ? warnings : [])
        @decisions[:escalation] = verdict
        verdict
      end

      def escalated_report(source, products, checkout, warnings, verdict)
        return escalation_report(source, products, checkout, warnings) unless verdict[:reason] == "mismatch"

        handoff_report(source, products, checkout, warnings,
                       outcome: "checkout_mismatch",
                       message: "Aborted before purchase — checkout didn't match the request: #{warnings.join(' ')}")
      end

      # One guard per gate, in the order they run: a payment token, the
      # buyer's spend policy, the opt-in confidence check, then the store's
      # own answer to the completion.
      def complete(session, source, products, checkout, warnings = [])
        @payment_token ||= PaymentMethods.default
        return no_payment_token_report(source, products, checkout, warnings) unless @payment_token

        held = held_report(source, products, checkout, warnings)
        return held if held

        completed = recording_transaction(source, checkout) do
          session.complete_checkout(checkout_id: checkout["id"], payment_token: @payment_token)
        end
        # `complete_checkout` can hand back `requires_escalation` too (e.g.
        # Shopify's cartSubmitForCompletion result carrying `errors`) — this
        # used to report "Purchased." unconditionally regardless of
        # `completed["status"]`, silently misreporting an escalation as a
        # successful purchase.
        return escalation_report(source, products, completed, warnings) if decide_escalation(completed, [])[:escalate]

        checkout_report(source, products, completed, outcome: "purchased", message: "Purchased.",
                                                     warnings: warnings + Array(@unrecorded_warning))
      rescue Portage::Ucp::Client::PaymentPermissionError
        permission_denied_report(source, products, checkout, warnings)
      end

      # PolicyGuard's rolling cap and velocity limit count the completed
      # records in the transaction log. On the own-store loopback path the
      # in-process Dispatcher writes those itself, so only a remote
      # completion is recorded here. Recording both would count a loopback
      # purchase twice.
      #
      # Same shape as Dispatcher's record: reserved `pending` before the
      # store is asked to complete, so a crash mid-charge leaves evidence,
      # then settled. Only a completion that came back purchased settles as
      # `complete`, the one status those limits count.
      def recording_transaction(source, checkout)
        return yield unless source == "native_ucp"

        key = "portage-buy:#{@uri.host}:#{checkout['id']}"
        transaction_log.reserve(idempotency_key: key, checkout_id: checkout["id"], shop: @uri.host,
                                payment_token_ref: token_ref, amount: checkout_total(checkout),
                                currency: checkout["currency"])
        begin
          completed = yield
        rescue StandardError
          transaction_log.complete(idempotency_key: key, status: "failed", policy_decision: @decisions[:policy])
          raise
        end
        settle_transaction(key, completed)
        completed
      end

      # Money has moved by now. TransactionLog raises on a failed write so
      # spend-cap state never drifts silently, but an escaped exception here
      # would drop the purchase's report and history entry too, so the
      # failure is put on the report as a warning instead.
      def settle_transaction(key, completed)
        purchased = Portage::Ucp::Support::Escalation.reason(checkout_status: completed["status"]).nil?
        transaction_log.complete(idempotency_key: key, status: purchased ? "complete" : "failed",
                                 amount: checkout_total(completed), currency: completed["currency"],
                                 policy_decision: @decisions[:policy])
      rescue StandardError => e
        @unrecorded_warning = "Purchased, but it couldn't be recorded in the transaction log (#{e.message}), " \
                              "so your spend policy's rolling cap and velocity limit won't count it."
      end

      def transaction_log
        @transaction_log ||= Portage::Ucp::Support::TransactionLog.new
      end

      # nil when both pre-completion gates pass; otherwise the report for
      # the first one that held the purchase.
      def held_report(source, products, checkout, warnings)
        policy = decide_policy(checkout)
        return policy_blocked_report(source, products, checkout, warnings, policy) unless policy[:allowed]

        confidence = decide_confidence(checkout, warnings)
        return nil if confidence.nil? || confidence[:proceed]

        handoff_report(source, products, checkout, warnings, outcome: "low_confidence",
                                                             message: low_confidence_message(confidence))
      end

      # The buyer's own spend policy (`portage policy set`), checked through
      # Decisions.policy before any completion is attempted. PolicyGuard is
      # core, so this runs with or without the optional decision gem.
      # Dispatcher runs PolicyGuard as well, but only in-process. A remote
      # native-UCP store's Dispatcher belongs to the merchant, not to this
      # buyer, so without this check the buyer's caps, allowlist and token
      # scopes never applied to a remote store at all. PolicyGuard.check!
      # only reads, so for the own-store adapter flow this repeats a check
      # Dispatcher also runs. It doesn't double-count anything.
      #
      # The rolling cap and velocity limit count the transaction log's
      # completed records: Dispatcher writes them for own-store purchases,
      # and #recording_transaction for remote ones.
      def decide_policy(checkout)
        verdict = Decisions.policy(amount: checkout_total(checkout), currency: checkout["currency"],
                                   merchant: @uri.host, token_ref: token_ref, transaction_log: transaction_log)
        @decisions[:policy] = verdict
        verdict
      end

      def token_ref = Portage::Ucp::Support::TokenRef.for(@payment_token)

      def checkout_total(checkout)
        Portage::Ucp::Support::Totals.amount(checkout["totals"])
      end

      # Never includes the payment token: the state goes to a model backend,
      # which may be a hosted API (Jev).
      def decide_confidence(checkout, warnings)
        verdict = confidence_check.call(
          query: @query, merchant: @uri.host, quantity: @qty, warnings: warnings,
          checkout: checkout.slice("id", "status", "currency", "line_items", "totals")
        )
        @decisions[:confidence] = verdict if verdict
        verdict
      end

      def confidence_check
        @confidence_check ||= ConfidenceCheck.new
      end

      def policy_blocked_report(source, products, checkout, warnings, verdict)
        handoff_report(source, products, checkout, warnings,
                       outcome: "policy_blocked",
                       message: "Blocked by your spend policy (#{verdict[:reason]}) — not completed. Review it " \
                                "with `portage policy show`, or visit the link to finish this checkout yourself.")
      end

      def low_confidence_message(verdict)
        backend = verdict[:backend]
        unless verdict[:reason] == "below_threshold"
          return "Confidence check (#{backend}) couldn't answer — not completed: #{verdict[:error]} " \
                 "Visit the link to finish this checkout yourself."
        end

        "Confidence check (#{backend}) scored this checkout #{verdict[:confidence].round(2)}, below the " \
          "#{verdict[:threshold]} threshold — not completed. Visit the link to review and finish it yourself."
      end

      def no_payment_token_report(source, products, checkout, warnings)
        handoff_report(source, products, checkout, warnings,
                       outcome: "no_payment_token",
                       message: "No --payment-token given, and no default payment method on file — run " \
                                "`portage payment enroll` or pass --payment-token, or visit the link to " \
                                "finish this checkout yourself.")
      end

      # Same posture as #escalation_report: a completion this agent isn't
      # granted permission for is a normal outcome, not a failure — the
      # shopper finishes on the merchant's own continue_url/checkout link,
      # same hand-off requires_escalation already uses (see
      # Client::PaymentPermissionError).
      def permission_denied_report(source, products, checkout, warnings)
        handoff_report(source, products, checkout, warnings,
                       outcome: "permission_denied",
                       message: "This agent isn't yet granted permission to complete checkout on this store — " \
                                "visit the link to finish it yourself.")
      end

      def escalation_report(source, products, checkout, warnings)
        handoff_report(source, products, checkout, warnings,
                       outcome: "requires_escalation",
                       message: "Checkout requires buyer escalation — visit the link to complete it.")
      end

      # Every checkout this process can't finish itself — a gate held it, or
      # the store escalated or refused permission — hands the shopper its URL
      # (and fires the auto-open/webhook side effects) rather than leaving
      # them at a dead end. `outcome` doubles as the webhook's `reason`, so a
      # relay and an agent loop branch on the same value.
      def handoff_report(source, products, checkout, warnings, outcome:, message:)
        handoff = hand_off(checkout, reason: outcome, source: source, message: message, warnings: warnings)
        checkout_report(source, products, checkout, outcome: outcome, warnings: warnings, message: message,
                                                    checkout_url: checkout_url_of(checkout), handoff: handoff)
      end

      # Never fires on --dry-run (a dry run creates a real checkout but never
      # attempts completion — auto-opening/notifying over a preview run would
      # be actively wrong), and never fires without a checkout_url to hand
      # off. Best-effort: a failed open or failed webhook POST never raises
      # out of #call (see CheckoutHandoff, Notifier), so the checkout itself
      # — created, or correctly escalated — stays the outcome of record
      # either way.
      #
      # The webhook body carries the report's own `message`, plus the store
      # and the shopper's query, so a Slack/Zapier relay can post it as-is
      # without a lookup back into this process.
      def hand_off(checkout, reason:, source:, message:, warnings:)
        url = checkout_url_of(checkout)
        return nil if @dry_run || url.nil?

        opened = CheckoutHandoff.new(auto_open: @auto_open).call(url)
        error = notifier.call(event: "checkout_handoff", reason: reason, message: message, store: @uri.to_s,
                              query: @query, checkout_url: url, checkout_id: checkout["id"], source: source,
                              totals: checkout["totals"], warnings: warnings)
        { url: url, opened: opened, notified: notifier.enabled? && error.nil?, notify_error: error }
      end

      def notifier
        @notifier ||= Notifier.new(webhook_url: @notify_webhook)
      end

      # `continue_url` first, because on a real store it is the only field
      # that ever holds the checkout. This used to be
      # `links.find { |l| l["url"] }` on the reasoning that not every
      # backend's link entries name a type — but live UCP stores put nothing
      # *except* policy links in `links`: five third-party Shopify stores
      # checked 2026-09-22 returned `refund_policy`, `privacy_policy`,
      # `terms_of_service`, `shipping_policy`, `contact_information` and
      # nothing else, with the checkout at `continue_url` every time. So the
      # old "first link with a url" handed the shopper a refund policy on
      # every real store, `--auto-open` opened it, and `--notify-webhook`
      # posted it.
      #
      # The `links` fallback stays for backends whose checkout genuinely
      # lives there, but skips anything named as a policy or contact link:
      # for a hand-off, no URL is a better answer than the wrong one, since
      # the report and the message both then say there's nowhere to go
      # instead of pointing somewhere useless.
      def checkout_url_of(checkout)
        checkout["continue_url"] || checkout_link_url(checkout)
      end

      def checkout_link_url(checkout)
        Array(checkout["links"])
          .reject { |l| l["type"].to_s.match?(POLICY_LINK_TYPES) }
          .find { |l| l["url"] }&.fetch("url", nil)
      end

      def confirmed?
        @yes
      end

      def dry_run_report(source, products, checkout, warnings = [])
        checkout_report(source, products, checkout, outcome: "dry_run", warnings: warnings,
                                                    message: "Dry run — checkout created but not completed.")
      end

      def confirmation_needed_report(source, products, checkout, warnings = [])
        checkout_report(source, products, checkout, outcome: "needs_confirmation", warnings: warnings,
                                                    message: "Checkout ready — pass --yes to confirm the purchase.")
      end

      # Flattens the parts of a Checkout wire hash a CLI caller actually
      # wants to see (id/status/totals) onto the report, rather than nesting
      # the raw hash under a key that'd collide with the boolean `checkout:`
      # field the output struct already reserves (§ output shape). `items:`
      # is what the checkout actually holds; `products:` is only what the
      # search returned, most of which was never bought.
      def checkout_report(source, products, checkout, outcome:, message:, checkout_url: nil, handoff: nil,
                          warnings: [])
        build_report(source: source, outcome: outcome, browse: true, checkout: true, products: products,
                     message: message, checkout_url: checkout_url, checkout_id: checkout["id"],
                     checkout_status: checkout["status"], currency: checkout["currency"],
                     totals: checkout["totals"], items: checkout_items(checkout), handoff: handoff,
                     warnings: warnings, decisions: @decisions.dup)
      end

      def checkout_items(checkout)
        Array(checkout["line_items"]).map do |line|
          { id: line.dig("item", "id"), title: line.dig("item", "title"), quantity: line["quantity"] }
        end
      end

      def safe_search(session)
        CatalogProducts.from(session.search_catalog(query: @query, limit: 10, context: buyer_context,
                                                    meta: agent_meta))
      end

      # A real store resolves which market — and so which inventory and
      # prices — a call is scoped to from this (see
      # Portage::Cli::BuyerContext). The loopback/stdio transports drop it.
      def buyer_context
        @buyer_context ||= BuyerContext.from_env.tap do |ctx|
          next unless ctx.empty?

          # See BuyerContext's own comment: a live Shopify store scoped a
          # cart to no market and dropped every line item with no context at
          # all, reporting `merchandise_out_of_stock` for products its own
          # search just returned. That failure mode looks like a store bug
          # from the report alone — this names the likely cause up front.
          warn "portage: no buyer context set (#{BuyerContext::ENV_VARS.values.join(', ')}) — some stores " \
               "drop line items or misprice without one. Set at least PORTAGE_SHIP_COUNTRY."
        end
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
          http.get(uri.request_uri, UserAgent.headers)
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
        build_report(source: "none", outcome: "dead_end", browse: false, checkout: false,
                     message: "No automated path — visit #{@uri} yourself.")
      end

      def build_report(**fields)
        { url: @uri.to_s, checkout_url: nil, products: [], warnings: [] }.merge(fields)
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

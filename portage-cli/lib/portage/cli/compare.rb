require_relative "find"

module Portage
  module Cli
    # `portage compare <url> --product-id ID` — §22's "find this same item
    # elsewhere" mode. Resolves a product a shopper already has in hand, then
    # runs Find's own candidate-discovery/probe/rank pipeline against the
    # product's own title, scoring each surviving offer by how confident we
    # actually are that it's the *same* item rather than just a similarly
    # titled one.
    #
    # Catalog-price only: nothing here calls create_checkout against a
    # candidate store, so a ranked offer's price is the listed price, never a
    # landed price. See docs/plans/portage-compare.md for why that's a
    # deliberate scope cut, not an oversight.
    class Compare < Find
      RESULT_LIMIT = 5
      TIER_RANK = { confirmed: 0, likely: 1, unconfirmed: 2 }.freeze

      # `identity:` is one repeatable value, not four aliases (--mpn/--sku/
      # --upc/--gtin) for the same untyped string corpus — the wire format
      # doesn't distinguish barcode types, so a flag name implying it could
      # would be lying about the matcher's actual precision. `find_options:`
      # bundles Find's own backends:/cache:/throttle: pass-through so this
      # initializer stays under Metrics/ParameterLists without an exclusion.
      def initialize(origin_url:, origin_product_id:, identity: [], results: RESULT_LIMIT, max_price: nil,
                     find_options: {})
        @origin_url = origin_url
        @origin_product_id = origin_product_id
        @explicit_identity = identity
        @result_limit = results
        # `query: nil` — the real query isn't known until #call resolves the
        # origin product; Find reads @query at #call time, not construction
        # time, so #call can overwrite it before invoking Find#call via super.
        super(query: nil, max_price: max_price, **find_options)
      end

      def call
        origin = resolve_origin
        return origin if origin[:message]

        @origin_host = origin[:host]
        @identity = build_identity(origin[:product])
        @query = origin[:title]
        result = super
        finish(result)
      end

      private

      # --- Origin resolution ---

      def resolve_origin
        uri = parse_http(@origin_url)
        return report(message: "Not a store URL: #{@origin_url.inspect}") unless uri

        session = discover(origin_of(uri))
        return report(message: "#{origin_of(uri)} doesn't speak UCP.") unless session

        wrapped = session.get_product(product_id: @origin_product_id)
        product = wrapped.is_a?(Hash) ? wrapped["product"] : nil
        return report(message: "Product #{@origin_product_id.inspect} not found at #{origin_of(uri)}.") unless product

        { host: uri.host, title: field(product, "title"), product: product }
      end

      # --- Identity ---

      # Explicit `--id` values win when given; otherwise fall back to the
      # origin product's own first variant sku/barcodes. First-variant-only,
      # same scope Find's own single-product reads already assume.
      def build_identity(product)
        variant = first_variant(product)
        { barcodes: normalize_all(barcode_values(variant)), sku: normalize(variant["sku"]),
          explicit: normalize_all(@explicit_identity) }
      end

      def first_variant(product) = Array(field(product, "variants")).first || {}

      def barcode_values(variant) = Array(variant["barcodes"]).filter_map { |b| b.is_a?(Hash) ? b["value"] : nil }

      def normalize(value)
        value = value.to_s.strip
        value.empty? ? nil : value.downcase
      end

      def normalize_all(values) = values.map { |v| normalize(v) }.compact.uniq

      # --- Candidate offers: stash identity + host for scoring/exclusion ---

      # Find#offer only flattens id/title/price/url off the top-level
      # product. Compare additionally needs each candidate's own variant
      # sku/barcodes (to score against) and a normalized store host (to
      # exclude the origin store by host rather than by string equality on
      # `store:`, which misses scheme/www differences) — kept scoped to
      # Compare rather than pushed into Find, since plain `find` has no use
      # for either.
      def offer(store, product)
        base = super
        return nil unless base

        variant = first_variant(product)
        identity_values = { barcodes: normalize_all(barcode_values(variant)), sku: normalize(variant["sku"]) }
        base.merge(identity_values: identity_values, store_host: parse_http(store[:origin])&.host)
      end

      # --- Finish: exclude origin, score, rank, truncate, rewrite message ---

      def finish(result)
        offers = result[:offers].reject { |o| same_host?(o[:store_host], @origin_host) }
        excluded_origin = result[:offers].length - offers.length
        scored = offers.map { |o| o.merge(match: match_tier(o)) }
        ranked = scored.sort_by { |o| [TIER_RANK[o[:match]], o[:checkout] ? 0 : 1, o[:amount] || 0] }
        kept = ranked.first(@result_limit)
        result.merge(offers: kept, message: compare_summary(kept, ranked.length - kept.length, excluded_origin))
      end

      def same_host?(candidate_host, origin_host)
        candidate_host && origin_host && candidate_host.downcase == origin_host.downcase
      end

      # Three tiers, honest about what the wire format can actually prove:
      # barcodes are the one value the spec treats as globally unique, so
      # only a shared barcode earns :confirmed. A shared SKU is merchant-
      # internal and collides across stores constantly, so it — and an
      # explicit --id hit that isn't a barcode match — lands in :likely.
      # Everything else rode in on the search query alone.
      def match_tier(offer)
        candidate = offer[:identity_values]
        return :confirmed if shared_barcode?(candidate[:barcodes])
        return :likely if shared_sku?(candidate[:sku]) || explicit_hit?(candidate)

        :unconfirmed
      end

      def shared_barcode?(candidate_barcodes) = @identity[:barcodes].intersect?(Array(candidate_barcodes))

      def shared_sku?(candidate_sku) = @identity[:sku] && candidate_sku && @identity[:sku] == candidate_sku

      def explicit_hit?(candidate)
        @identity[:explicit].intersect?((Array(candidate[:barcodes]) + [candidate[:sku]]).compact)
      end

      def compare_summary(kept, truncated, excluded_origin)
        return empty_compare_summary(excluded_origin) if kept.empty?

        parts = ["Found #{kept.length} offer(s) for \"#{@query}\""]
        parts << "#{truncated} more not shown (--results #{@result_limit})" if truncated.positive?
        parts << "#{excluded_origin} excluded (origin store)" if excluded_origin.positive?
        "#{parts.join(', ')}."
      end

      def empty_compare_summary(excluded_origin)
        message = "No comparable offers found for \"#{@query}\" outside #{@origin_host}"
        message += ", #{excluded_origin} excluded (origin store)" if excluded_origin.positive?
        "#{message}."
      end
    end
  end
end

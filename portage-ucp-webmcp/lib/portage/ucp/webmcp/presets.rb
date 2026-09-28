module Portage
  module Ucp
    module WebMcp
      # Built-in `tool_names:`/`wire:` mappings for platforms whose WebMCP
      # pages are known to register one fixed tool set, so a caller doesn't
      # have to pass `tool_names:` by hand against every store running that
      # platform (docs/plans/webmcp-universal-outbound.md).
      #
      # `Presets.detect` picks a preset only from an exact match against the
      # tool names a page registers *right now* — never from anything the
      # page's own text says about itself (a `generator` meta tag,
      # `window.Shopify`, a tool's own description). Any of that is page
      # content, which is untrusted; a fingerprint is what the mapping
      # actually depends on, and forging one costs registering all of it.
      module Presets
        # @!attribute checkout_selectors
        #   [Hash{String=>String}] Phase 3 (docs/plans/
        #   webmcp-universal-outbound.md) fallback CSS selectors, keyed by
        #   the same autocomplete token `Autofill`/assets/autofill.js
        #   already tries first — only reached when the checkout page's own
        #   markup doesn't carry a matching `autocomplete` attribute for
        #   that field.
        Preset = Struct.new(:tool_names, :wire, :fingerprint, :handoff_checkout, :checkout_selectors,
                            keyword_init: true) do
          def checkout_selectors = self[:checkout_selectors] || {}
        end

        # Shopify's own WebMCP tools (`window.Shopify.actions`, not this
        # gem's registrar). Fingerprint taken live on 2026-09-28: ColourPop,
        # tentree, Kylie Cosmetics, Brooklinen, Allbirds, Billabong and The
        # Light Yard all register exactly these 11 tools, with identical
        # input schemas (Gymshark and Fashion Nova register none). Shopify
        # can change this set without notice; when it does, `detect` misses
        # and the page is treated as unknown rather than mapped wrongly.
        #
        # `update_cart_lines` (addresses existing cart lines by line id, not
        # by variant) and `proceed_to_checkout` (a navigation, not data)
        # don't fit any Session method's contract, so neither gets a
        # `tool_names:` entry — see the README's "Shopify storefronts"
        # section. `proceed_to_checkout` is instead named as
        # `handoff_checkout:`, the hand-off-only checkout tool Capabilities
        # counts as checkout (decision 1) and Buy's WebMCP flow calls
        # directly rather than through Session. `browse_store`,
        # `show_variant`, `manage_orders` and `search_shop_policies_and_faqs`
        # are left unmapped: none has been checked against a Session method.
        SHOPIFY = Preset.new(
          tool_names: { create_cart: "add_to_cart" },
          wire: :auto,
          fingerprint: %w[search_catalog browse_store get_product show_variant add_to_cart get_cart
                          update_cart_lines cancel_cart proceed_to_checkout manage_orders
                          search_shop_policies_and_faqs].freeze,
          handoff_checkout: "proceed_to_checkout",
          # No live check has confirmed any selector against a real Shopify
          # checkout page (Phase 3 shipped with no browser/live storefront
          # available this session — see the plan's Progress log). Left
          # empty rather than guessed: Shopify Checkout's own contact/
          # shipping fields are documented to carry standard `autocomplete`
          # values, so `Autofill`'s own attribute match should reach them
          # without a fallback — but that's unverified, not assumed safe.
          checkout_selectors: {}.freeze
        ).freeze

        ALL = { shopify: SHOPIFY }.freeze

        # @param tools [Array<Hash>] a page's tools, as Bridge#list_tools/
        #   Transport#tools returns them.
        # @return [Symbol, nil] the preset whose fingerprint is the exact set
        #   of names the page registers, or nil when none matches (an
        #   unrecognized page, or a known platform whose tool set has since
        #   changed).
        def self.detect(tools)
          names = Fingerprint.names(tools)
          ALL.find { |_key, preset| preset.fingerprint.sort == names }&.first
        end

        # @param name [Symbol]
        # @return [Preset]
        def self.fetch(name) = ALL.fetch(name)
      end
    end
  end
end

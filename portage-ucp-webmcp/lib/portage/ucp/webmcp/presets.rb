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
          # Taken live on 2026-09-28 against The Light Yard's checkout
          # (design-log §50). Shopify prefixes every contact/shipping token
          # with the "shipping" section and uses different detail tokens for
          # two of the fields WebmcpAutofillFields asks for: the email field
          # is `shipping email` (not `email`) and the phone field is
          # `shipping tel-national` (not `shipping tel`). Both selectors
          # match on that attribute, not on Shopify's generated ids. Every
          # other field matched by its own autocomplete value. `shipping
          # country` hits Shopify's own autofill-capture input, which
          # Shopify copies into the country `<select>` itself.
          checkout_selectors: {
            "email" => "input[autocomplete='shipping email']",
            "shipping tel" => "input[autocomplete='shipping tel-national']"
          }.freeze
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

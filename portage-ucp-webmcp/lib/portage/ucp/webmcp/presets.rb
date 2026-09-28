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
        Preset = Struct.new(:tool_names, :wire, :fingerprint, :handoff_checkout, keyword_init: true)

        # Shopify's own WebMCP tools (`window.Shopify.actions`, not this
        # gem's registrar). A live sweep across 6 Shopify storefronts
        # (README "Shopify storefronts", 2026-09-23) counted 11 tools per
        # store but only named 7 of them: `search_catalog`, `get_product`,
        # `add_to_cart`, `get_cart`, `cancel_cart`, `update_cart_lines`,
        # `proceed_to_checkout`. Those 7 are all this fingerprint lists —
        # the other 4 aren't sourced anywhere in this repo, and this plan's
        # own Phase 1 live check (rerunning that sweep under `preset:
        # :auto`) is what's expected to fill them in or correct this list.
        # Until that check runs, `detect` won't match a real Shopify page
        # that registers the full 11 (see docs/plans/
        # webmcp-universal-outbound.md, Phase 1 and the Progress log).
        #
        # `update_cart_lines` (addresses existing cart lines by line id, not
        # by variant) and `proceed_to_checkout` (a navigation, not data)
        # don't fit any Session method's contract, so neither gets a
        # `tool_names:` entry — see the README's "Shopify storefronts"
        # section. `proceed_to_checkout` is instead named as
        # `handoff_checkout:`, the hand-off-only checkout tool Capabilities
        # counts as checkout (decision 1) and Buy's WebMCP flow calls
        # directly rather than through Session.
        SHOPIFY = Preset.new(
          tool_names: { create_cart: "add_to_cart" },
          wire: :auto,
          fingerprint: %w[search_catalog get_product add_to_cart get_cart cancel_cart update_cart_lines
                          proceed_to_checkout].freeze,
          handoff_checkout: "proceed_to_checkout"
        ).freeze

        ALL = { shopify: SHOPIFY }.freeze

        # @param tools [Array<Hash>] a page's tools, as Bridge#list_tools/
        #   Transport#tools returns them.
        # @return [Symbol, nil] the preset whose fingerprint is the exact set
        #   of names the page registers, or nil when none matches (an
        #   unrecognized page, or a known platform whose tool set has since
        #   changed).
        def self.detect(tools)
          names = tools.map { |tool| (tool["name"] || tool[:name]).to_s }.sort
          ALL.find { |_key, preset| preset.fingerprint.sort == names }&.first
        end

        # @param name [Symbol]
        # @return [Preset]
        def self.fetch(name) = ALL.fetch(name)
      end
    end
  end
end

module Portage
  module Ucp
    module WebMcp
      # Phase 3 (docs/plans/webmcp-universal-outbound.md): drives the same
      # bridge's browser that already holds the cart to fill the store's own
      # checkout page — contact email and shipping address, nothing else.
      # This module only decides *whether* to run the page script and what
      # to make of its result; the actual DOM work (finding fields,
      # refusing payment ones, detecting a challenge) lives entirely in
      # assets/autofill.js, evaluated through Bridges::ScriptEvaluator#autofill.
      #
      # portage-cli owns everything upstream of this: the opt-in gate
      # (WebmcpAutofillMode), the shopper-approval prompt
      # (WebmcpAutofillConfirm), and building `fields` from PORTAGE_SHIP_*
      # (WebmcpAutofillFields) — this module never reads shopper data or a
      # config file itself. It exists in this gem, not portage-cli, because
      # it's the piece that actually has to know the Bridge/Preset shapes.
      module Autofill
        Result = Struct.new(:outcome, :filled, :unmatched, :rate, keyword_init: true) do
          def ok? = outcome == :filled
        end

        # @param bridge [#autofill, #headless?] the same Bridge already
        #   holding the cart, now pointed at the checkout page a preset's
        #   `handoff_checkout` tool navigated it to.
        # @param fields [Hash{String=>String}] autocomplete token => value,
        #   already shopper-approved — this module fills exactly these and
        #   nothing more.
        # @param selectors [Hash{String=>String}] a preset's fallback CSS
        #   selectors (Presets::Preset#checkout_selectors).
        # @return [Result] outcome is :filled (ran; #filled/#unmatched say
        #   what matched), :needs_headed_browser (bridge is headless, or
        #   never said either way — see ScriptEvaluator.ferrum's note on why
        #   "unknown" is treated as headless), :blocked (a CAPTCHA/challenge
        #   was on the page; nothing was touched), or :unsupported (this
        #   bridge doesn't implement #autofill at all — a hand-rolled Bridge
        #   that only meets the base #list_tools/#execute_tool contract).
        def self.call(bridge:, fields:, selectors: {})
          return unsupported(fields) unless bridge.respond_to?(:autofill)
          return needs_headed_browser(fields) if headless?(bridge)
          return Result.new(outcome: :filled, filled: [], unmatched: [], rate: []) if fields.empty?

          from_page(bridge.autofill(fields, selectors: selectors))
        end

        def self.from_page(value)
          return Result.new(outcome: :blocked, filled: [], unmatched: [], rate: []) if value["blocked"]

          Result.new(outcome: :filled, filled: Array(value["filled"]), unmatched: Array(value["unmatched"]),
                     rate: Array(value["rate"]))
        end
        private_class_method :from_page

        # A bridge that never declares itself headless: false is treated as
        # headless — the shopper has to be able to see and pay in this
        # browser, so "unknown" is the safe default, not "assume headed".
        def self.headless?(bridge)
          !(bridge.respond_to?(:headless?) && bridge.headless? == false)
        end
        private_class_method :headless?

        def self.unsupported(fields)
          Result.new(outcome: :unsupported, filled: [], unmatched: fields.keys, rate: [])
        end
        private_class_method :unsupported

        def self.needs_headed_browser(fields)
          Result.new(outcome: :needs_headed_browser, filled: [], unmatched: fields.keys, rate: [])
        end
        private_class_method :needs_headed_browser
      end
    end
  end
end

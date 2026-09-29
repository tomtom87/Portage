require_relative "history"
require_relative "quotes"
require_relative "human_prompt"
require_relative "product_page"
require_relative "money"
require_relative "approval_policy"

module Portage
  module Cli
    # `portage approve QUOTE_ID` — loop step 5, the person says yes to the
    # exact dry-run total (docs/plans/human-pick-and-approve.md Phase 2,
    # Design § 5). Shows title, store, qty and total and asks yes/no.
    #
    # A yes typed on the `tty` surface marks the quote `approved_by:
    # "person"`; `--relayed-yes` marks it `"agent_relayed"`. The `agent`
    # surface asks nobody and returns `needs_approval` with the summary.
    # `--view` only opens the product page. Whether an approval is enough
    # for `buy --quote QUOTE_ID --yes` is ApprovalPolicy's call, at buy time
    # — except under `person`, where a relayed yes could never be enough, so
    # it isn't recorded and the agent is told to hand the question to the
    # person's own terminal instead.
    #
    # Returns a report hash; Cli.run_approve prints it.
    class Approve
      def initialize(quote_id:, prompt:, relayed_yes: false, view: false, quotes: Quotes.new, history: History.new,
                     level: ApprovalPolicy.level)
        @quote_id = quote_id
        @prompt = prompt
        @relayed_yes = relayed_yes
        @view = view
        @quotes = quotes
        @history = history
        @level = level
      end

      def call
        quote = @quotes.find(@quote_id)
        return unusable(quote) if quote.nil? || quote["used_at"]

        summary = self.class.summary(quote, history: @history)
        return view(summary) if @view
        return relay(summary) if @relayed_yes
        return self.class.needs_approval(summary, level: @level) unless @prompt.tty?

        ask(summary)
      rescue HumanPrompt::NoTerminal => e
        { outcome: "no_terminal", quote_id: @quote_id, message: e.message }
      end

      # What the person is asked to approve. Title and url were saved on
      # the quote at dry-run time; a quote saved without them falls back to
      # its offer's (via `offer_ref`, History#offer).
      def self.summary(quote, history: History.new)
        offer = fallback_offer(quote, history)
        { quote_id: quote["quote_id"], title: quote["title"] || offer&.dig("title"), store: quote["store"],
          product_id: quote["product_id"], qty: quote["qty"], total: quote["total"], currency: quote["currency"],
          total_display: quote["total"] ? Money.format_amount(quote["total"], quote["currency"]) : "unknown",
          url: quote["url"] || offer&.dig("url"), approved_by: quote["approved_by"] }
      end

      def self.fallback_offer(quote, history)
        return nil unless quote["offer_ref"] && (quote["title"].nil? || quote["url"].nil?)

        history.offer(quote["offer_ref"])
      end
      private_class_method :fallback_offer

      # Also what a refused `buy --yes` returns (Cli.approval_gate).
      def self.needs_approval(summary, message: nil, level: ApprovalPolicy::DEFAULT)
        { outcome: "needs_approval", quote_id: summary[:quote_id], summary: summary,
          message: message || relay_message(summary, level) }
      end

      def self.relay_message(summary, level)
        id = summary[:quote_id]
        ask = if level == "person"
                "Ask the person to run `portage approve #{id}` in their own terminal (require_approval: person " \
                  "doesn't accept a relayed yes)"
              else
                "Ask the person to approve #{describe(summary)} (show the url as a link), then relay a yes: " \
                  "`portage approve #{id} --relayed-yes`"
              end
        "#{ask}, then `portage buy --quote #{id} --yes`."
      end
      private_class_method :relay_message

      def self.describe(summary)
        "#{summary[:qty]} × #{summary[:title] || summary[:product_id]} from #{summary[:store]} " \
          "for #{summary[:total_display]}"
      end

      private

      def ask(summary)
        @prompt.say("#{summary[:title] || summary[:product_id]} — #{summary[:store]}")
        @prompt.say("  qty #{summary[:qty]}, total #{summary[:total_display]}#{" — #{summary[:url]}" if summary[:url]}")
        yes = @prompt.confirm("Buy #{self.class.describe(summary)}?", view: -> { page(summary)[:message] })
        return approve(summary, HumanPrompt::BY_PERSON) if yes

        { outcome: "cancelled", quote_id: summary[:quote_id], message: "Not approved — nothing will be bought." }
      end

      def relay(summary)
        return self.class.needs_approval(summary, level: @level) if @level == "person"

        approve(summary, HumanPrompt::BY_AGENT)
      end

      def approve(summary, by)
        quote = @quotes.approve(summary[:quote_id], by: by)
        return { outcome: "error", quote_id: @quote_id, message: "Couldn't save the approval." } unless quote

        { outcome: "approved", quote_id: summary[:quote_id], approved_by: quote["approved_by"],
          summary: summary.merge(approved_by: quote["approved_by"]),
          message: "Approved #{self.class.describe(summary)} — next: " \
                   "`portage buy --quote #{summary[:quote_id]} --yes`." }
      end

      def view(summary) = page(summary).merge(quote_id: summary[:quote_id])

      def page(summary) = ProductPage.new(url: summary[:url], store: summary[:store]).open

      # Same outcomes `buy --quote` reports for the same two cases.
      def unusable(quote)
        if quote
          { outcome: "quote_used", quote_id: @quote_id,
            message: "Quote #{@quote_id} has already been used — dry-run again for a new one." }
        else
          { outcome: "quote_not_found", quote_id: @quote_id,
            message: "No saved quote #{@quote_id} — run `portage buy ... --dry-run --json` for a new one." }
        end
      end
    end
  end
end

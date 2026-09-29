require_relative "history"
require_relative "human_prompt"
require_relative "product_page"
require_relative "offer_choice"

module Portage
  module Cli
    # `portage pick` — loop step 3, the person picks the store
    # (docs/plans/human-pick-and-approve.md Phase 2, Design § 4). The
    # choices are a saved search's offers (History, `--search LAST` by
    # default) plus one more, "Compare an offer across stores", which runs
    # `compare` on the offer the person names and shows the pick again over
    # its results (the compared offer first, so it can still be chosen).
    #
    # On the `tty` surface the person answers on /dev/tty (`by: "person"`).
    # On the `agent` surface it returns `needs_pick` with `choices[]`; the
    # agent relays the answer with `--choose REF` (`by: "agent_relayed"`)
    # or `--compare REF`. `--view REF` only opens that offer's product page.
    #
    # Returns a report hash; Cli.run_pick prints it.
    class Pick
      COMPARE_REF = "compare".freeze
      COMPARE_LABEL = "Compare an offer across stores".freeze

      # @param comparer [#call] a saved (string-keyed) offer -> a Compare report.
      def initialize(prompt:, search: nil, choose: nil, view: nil, compare: nil, history: History.new,
                     comparer: nil)
        @prompt = prompt
        @search_id = search
        @choose = choose
        @view = view
        @compare = compare
        @history = history
        @comparer = comparer
      end

      def call
        return view_offer if @view

        search = @history.search(@search_id)
        return search_not_found unless search
        return compare_from_flag(search) if @compare
        return relayed(search) if @choose
        return needs_pick(search) unless @prompt.tty?

        ask(search)
      rescue HumanPrompt::NoTerminal => e
        { outcome: "no_terminal", message: e.message }
      end

      private

      # --- tty ---

      def ask(search)
        loop do
          offers = search["offers"]
          index = @prompt.choose("Pick an offer", choices(search), view: OfferChoice.method(:view_message))
          return cancelled unless index
          return picked(search, offers[index], HumanPrompt::BY_PERSON) if index < offers.length

          search = ask_compare(search)
          return cancelled unless search
        end
      end

      # @return [Hash, nil] the search to pick from next (the compare's, or
      #   the same one when it found nothing), nil when cancelled.
      def ask_compare(search)
        offers = search["offers"]
        index = @prompt.choose("Compare which offer?", offers.map { |o| OfferChoice.for(o) },
                               view: OfferChoice.method(:view_message))
        return nil unless index

        compared, message = compared(search, offers[index])
        @prompt.say(message)
        compared
      end

      # --- agent ---

      def needs_pick(search, message: nil)
        { outcome: "needs_pick", search_id: search["search_id"], query: search["query"], choices: choices(search),
          message: message || "Show these choices to the person (with each url as a link), then relay their " \
                              "answer: `portage pick --search #{search['search_id']} --choose REF`, or " \
                              "`--compare REF` for \"#{COMPARE_LABEL}\"." }
      end

      def relayed(search)
        offer = offer_in(search, @choose)
        return not_in_search(search, @choose) unless offer

        picked(search, offer, HumanPrompt::BY_AGENT)
      end

      def compare_from_flag(search)
        offer = offer_in(search, @compare)
        return not_in_search(search, @compare) unless offer

        compared, message = compared(search, offer)
        @prompt.tty? ? ask(compared) : needs_pick(compared, message: message)
      end

      # --- compare ---

      # Saved as a search of its own, so its offers get refs `buy --offer`
      # and `pick --choose` resolve: the compared offer first (bought by its
      # own query), then the results (bought by the compared product's
      # title, which is what compare searched for).
      # @return [Array(Hash, String)] the search to show next, and a message.
      def compared(search, offer)
        report = @comparer.call(offer)
        return [search, report[:message].to_s] if Array(report[:offers]).empty?

        origin = offer.merge("query" => offer["query"] || search["query"])
        results = report[:offers].map { |o| o.merge(query: report[:query]) }
        saved = @history.record_search(query: "compare: #{offer['store']} (product #{offer['product_id']})",
                                       offer_count: results.length, message: report[:message],
                                       offers: [origin] + results)
        [saved, report[:message].to_s]
      end

      # --- view ---

      def view_offer
        offer = @history.offer(@view)
        return unknown_offer(@view) unless offer

        ProductPage.new(url: offer["url"], store: offer["store"]).open.merge(offer_ref: @view)
      end

      # --- shapes ---

      def choices(search)
        search["offers"].map { |o| OfferChoice.for(o) } +
          [{ ref: COMPARE_REF, label: COMPARE_LABEL, url: nil,
             relay: "portage pick --search #{search['search_id']} --compare REF" }]
      end

      def offer_in(search, ref) = search["offers"].find { |o| o["offer_ref"] == ref }

      def picked(search, offer, by)
        { outcome: "picked", search_id: search["search_id"], offer_ref: offer["offer_ref"], store: offer["store"],
          product_id: offer["product_id"], title: offer["title"], url: offer["url"], by: by,
          message: "Picked #{offer['title']} from #{offer['store']} — next: " \
                   "`portage buy --offer #{offer['offer_ref']} --dry-run`." }
      end

      def cancelled = { outcome: "cancelled", message: "Nothing picked." }

      def search_not_found
        latest = @search_id.nil? || @search_id.casecmp?("last")
        what = latest ? "No saved search with offers" : "No search #{@search_id}"
        { outcome: "search_not_found", search_id: @search_id, message: "#{what} — run `portage find` first." }
      end

      def not_in_search(search, ref)
        { outcome: "offer_not_found", search_id: search["search_id"], offer_ref: ref,
          message: "#{ref} isn't one of search #{search['search_id']}'s offers." }
      end

      def unknown_offer(ref)
        { outcome: "offer_not_found", offer_ref: ref, message: "No saved offer #{ref} — run `portage find` again." }
      end
    end
  end
end

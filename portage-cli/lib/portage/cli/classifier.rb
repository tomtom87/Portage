require "yaml"

module Portage
  module Cli
    # "What category is this?" for anything shopping-shaped: a search query,
    # a catalog product's title/description, a stores.yml/index entry, or
    # (Phase 3) a browser history/bookmark entry — one classifier, so a
    # store tagged from its product mix and a query typed by a shopper land
    # in the same category space and can be matched against each other.
    #
    # Plain keyword matching against Google's own published product taxonomy
    # (https://www.google.com/basepages/producttype/taxonomy-with-ids.en-US.txt),
    # top two levels only (~200 nodes, `known-stores/categories.yml`, shipped
    # in the gem so this works offline on a fresh brew/gem install). No LLM
    # and no network call: it has to run on every `find` and stay instant.
    # "Plain keyword" means a whole-word match (plus simple plural
    # normalization, #word_match?), not a substring regex — a substring
    # check matches in both directions ("carpet" contains "pet", "chair"
    # contains "hair", "scarf" contains "car") and was a real source of
    # false positives before this became whole-word.
    module Classifier
      # `known-stores/categories.yml`, from `lib/portage/cli/classifier.rb`.
      KNOWN_PATH = File.expand_path("../../../known-stores/categories.yml", __dir__).freeze

      # The user's own additions/overrides — same id overrides a shipped
      # node's keywords, a new id extends the taxonomy. Absent by default;
      # nothing here is required for the shipped file to work.
      PATH = File.join(Dir.home, ".portage", "categories.yml").freeze

      # `/products/<slug>`, `/collections/<slug>`, `/c/<slug>`,
      # `/category/<slug>` — the URL shapes stores.yml/index/browser-import
      # entries actually carry (docs/plans/buy-skill-and-local-browser.md
      # Phase 2a/3).
      SLUG_PATTERNS = [
        %r{/products/([^/?#]+)},
        %r{/collections/([^/?#]+)},
        %r{/c/([^/?#]+)},
        %r{/category/([^/?#]+)}
      ].freeze

      # @param text [String] a query, a product title/description, or a
      #   store/product URL. Whichever it is, it's tokenized the same way
      #   (see #tokenize) so the same node keywords match all of them.
      # @param known_path [String] override for KNOWN_PATH — specs redirect
      #   this the same way SearchBackends::Allowlist takes its own `path:`.
      # @param user_path [String] override for PATH.
      # @return [Array<String>] category ids, most keyword hits first. Ties
      #   keep the shipped file's own order. Empty when nothing matches.
      def self.categories_for(text, known_path: KNOWN_PATH, user_path: PATH)
        words = tokenize(text).to_h { |word| [word, true] }
        return [] if words.empty?

        scored = nodes(known_path, user_path).filter_map { |id, node| rank(id, node, words) }
        scored.sort_by { |(_id, score, order)| [-score, order] }.map(&:first)
      end

      # @return [Array<String>] the taxonomy names for `ids`, in order —
      #   `portage browser import` (Phase 3) shows a domain's guessed
      #   categories by name so the user can judge them before saving.
      def self.names_for(ids, known_path: KNOWN_PATH, user_path: PATH)
        all = nodes(known_path, user_path)
        Array(ids).filter_map { |id| all.dig(id.to_s, "name") }
      end

      # --- Tokenizing the input ---

      # A URL slug is words joined by `-`/`_` (`hand-cut-glass` — see
      # AGENTS.md's own product terminology); everything else is just
      # whitespace/punctuation-split. Both a URL's slug words and the plain
      # words of a title/description/query are kept, so "hiking boots" and
      # "https://shop.example/products/hiking-boots-mens" tokenize the same
      # way.
      # Below 3 letters, a token is noise ("a", "of", "is") rather than a
      # keyword candidate — every generated keyword is at least this long
      # too (see the script that built known-stores/categories.yml), so
      # nothing below this length could ever whole-word match one anyway.
      MIN_WORD_LENGTH = 3

      # Public rather than private — SearchBackends::Index (Phase 2b) tokenizes
      # a query and a product's title/aliases the same way this module does
      # internally, so a query and a product name land in the same word
      # space instead of re-implementing this split.
      def self.tokenize(text)
        string = text.to_s
        slug_words = SLUG_PATTERNS.filter_map { |pattern| pattern.match(string)&.[](1) }
                                  .flat_map { |slug| slug.split(/[-_]/) }
        (slug_words + string.split(/[^\p{Alpha}]+/)).map(&:downcase)
                                                    .select { |word| word.length >= MIN_WORD_LENGTH }
      end

      # --- Scoring one node against the tokenized input ---

      # `words` is a Hash of word => true: each keyword checks its few #word_match? forms
      # against it, rather than every word against every keyword — the
      # same matches, but a long product-tag text (Index::Sources::
      # StorefrontProducts, docs/plans/local-catalogue.md Phase 2) no
      # longer costs words x keywords comparisons.
      def self.rank(id, node, words)
        keywords = Array(node["keywords"])
        hits = keywords.count { |keyword| match_forms(keyword).any? { |form| words.key?(form) } }
        return nil unless hits.positive?

        [id, hits, node["order"].to_i]
      end
      private_class_method :rank

      # Every word #word_match? accepts for `keyword`: itself, its "s"/"es"
      # plurals, the singular it is a plural of, and the "y"/"ies" swap.
      def self.match_forms(keyword)
        forms = [keyword, "#{keyword}s", "#{keyword}es"]
        forms << keyword.delete_suffix("s") if keyword.end_with?("s")
        forms << keyword.delete_suffix("es") if keyword.end_with?("es")
        forms << "#{keyword[0..-2]}ies" if keyword.end_with?("y")
        forms << "#{keyword[0..-4]}y" if keyword.end_with?("ies")
        forms
      end
      private_class_method :match_forms

      # Whole-word only, plus the plural forms a keyword list and a real
      # query/title actually differ by: an exact match, one plus a trailing
      # "s" or "es" ("boot"/"boots", "watch"/"watches"), or the "y"/"ies"
      # swap ("battery"/"batteries"). Deliberately not a substring check —
      # substrings match in both directions regardless of word boundaries
      # ("carpet" contains "pet", "chair" contains "hair", "scarf" contains
      # "car"), which is real noise, not stemming.
      # Public — see .tokenize's own comment; SearchBackends::Index (Phase
      # 2b) matches a query's tokens against a product's title/alias tokens
      # with this same whole-word (plus plural) rule, rather than a
      # substring check that goes both ways ("tea" in "steam"/"teak", "bag"
      # in "bagel").
      def self.word_match?(word, keyword)
        word == keyword || plural_of?(word, keyword) || plural_of?(keyword, word) || ies_y_match?(word, keyword)
      end

      # @return [Boolean] true when `plural` is `singular` plus a trailing
      # "s" or "es" ("boot"/"boots", "watch"/"watches").
      def self.plural_of?(plural, singular)
        ["#{singular}s", "#{singular}es"].include?(plural)
      end
      private_class_method :plural_of?

      # @return [Boolean] true when either side is the other's "ies" plural
      # ("battery"/"batteries").
      def self.ies_y_match?(word, keyword)
        (word.end_with?("ies") && keyword == "#{word[0..-4]}y") ||
          (keyword.end_with?("ies") && word == "#{keyword[0..-4]}y")
      end
      private_class_method :ies_y_match?

      # --- Loading and merging the two files ---

      # Re-read on every call rather than cached process-wide: `find` calls
      # this once or twice per invocation, not in a hot loop, and a cached
      # copy would miss an edit to ~/.portage/categories.yml until the next
      # process start.
      def self.nodes(known_path, user_path)
        ordered = {}
        load_yaml(known_path).each_with_index { |(id, node), i| ordered[id] = node.merge("order" => i) }
        load_yaml(user_path).each_with_index { |(id, node), i| ordered[id] = node.merge("order" => ordered.size + i) }
        ordered
      end
      private_class_method :nodes

      def self.load_yaml(path)
        return {} unless path && File.readable?(path)

        data = YAML.safe_load_file(path)
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end
      private_class_method :load_yaml
    end
  end
end

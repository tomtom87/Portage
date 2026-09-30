module Portage
  module Cli
    module Classifier
      # Scores the tokenized input against every node and keeps the best few
      # (docs/plans/local-catalogue.md, Phase 5). Nodes carry hundreds of
      # rolled-up keywords, so this is where "a generic word matches a dozen
      # categories" gets dealt with.
      module Ranking
        # A node's own name words and its descendants' (`keywords`) say what
        # the product is; its parent's (`parent_keywords`, e.g. "home",
        # "garden") only where it is filed, so they count half as much.
        KEYWORD_WEIGHT = 2
        PARENT_WEIGHT = 1

        # Callers treat every returned id as evidence (store routing, a
        # browser domain's category tally), so the answer keeps only the best
        # MAX_CATEGORIES ids and, of those, only ones scoring at least
        # 1/CUTOFF of the best: "electric kettle" is Kitchen & Dining, not
        # also Chairs because of "electric".
        MAX_CATEGORIES = 3
        CUTOFF = 2

        module_function

        # @param counts [Hash{String => Integer}] word => times the input says it.
        # @param table [Classifier::Table]
        # @param stopped [Hash] the stoplist.
        # @return [Array<String>] up to MAX_CATEGORIES node ids, best first.
        def best(counts, table, stopped)
          ranked = score(counts, table).map do |id, (score, evidence)|
            [id, score, evidence, *tie_breakers(table.nodes[id], counts.keys, stopped)]
          end
          ranked = ranked.sort_by { |(_id, score, _evidence, *rest)| [-score.round(6), *rest] }
          cut(ranked).first(MAX_CATEGORIES).map(&:first)
        end

        # The first row always stays; later rows only if strong?.
        def cut(ranked)
          strongest = ranked.map { |row| row[2] }.max
          ranked.each_with_index.select { |row, i| i.zero? || strong?(row[2], strongest) }.map(&:first)
        end

        # Distinct input words and how often each occurs. A plural variant of
        # a word counts as the same word ("pendant" and "Pendants").
        def word_counts(tokens)
          tokens.each_with_object({}) do |token, counts|
            word = counts.keys.find { |known| Classifier.word_match?(token, known) } || token
            counts[word] = counts.fetch(word, 0) + 1
          end
        end

        # @return [Hash{String => Array(Float, Float)}] node id => [score,
        #   evidence], for nodes scoring above zero. Each word counts once for
        #   a node, however many of its keywords match ("light" and "lights"
        #   are two keywords but one word of the input), so a node cannot win
        #   by listing a word's variants: KEYWORD_WEIGHT when a `keywords`
        #   entry matches, PARENT_WEIGHT when only a `parent_keywords` entry
        #   does, times how often the input says the word (1 + ln count: a
        #   Shopify tag list repeats "Pendant Lights" once per room, which is
        #   its best evidence, and the log keeps a long tag list from burying
        #   a different word). `evidence` is the same sum with each word also
        #   weighted by how rare it is (ln(1 + nodes / nodes it matches)), so
        #   "kettle" counts for more than "electric".
        def score(counts, table)
          scores = Hash.new { |hash, id| hash[id] = [0.0, 0.0] }
          counts.each do |word, count|
            contributions(word, count, table).each { |id, weight, rarity| add(scores[id], weight, rarity) }
          end
          scores
        end

        # @return [Array<Array(String, Float, Float)>] [node id, weight,
        #   rarity] for every node `word` matches.
        def contributions(word, count, table)
          own = matching_ids(word, table.own)
          parent = matching_ids(word, table.parent) - own
          return [] if own.empty? && parent.empty?

          tf = 1 + Math.log(count)
          rarity = Math.log(1 + table.nodes.size.fdiv((own + parent).length))
          own.map { |id| [id, KEYWORD_WEIGHT * tf, rarity] } + parent.map { |id| [id, PARENT_WEIGHT * tf, rarity] }
        end

        def add(pair, weight, rarity)
          pair[0] += weight
          pair[1] += weight * rarity
        end

        # Ranking by `score` alone is what classifies a long tag list best,
        # because rare words are mostly noise there (a room name in a
        # lighting store's tags). The cut uses `evidence`, which a generic
        # word cannot fill: an id beyond the first stays only if its evidence
        # reaches 1/CUTOFF of the strongest.
        def strong?(evidence, strongest) = (evidence * CUTOFF) - strongest > -1e-9

        # What separates nodes with equal scores, best first: the share of
        # the node's own name the input covers ("Sofas" before "Sofa
        # Accessories" for "sofa"), then a name with no stoplisted word in it
        # ("Household Appliances" before "Household Appliance Accessories"),
        # then fewer keywords (the smaller node is the more specific one),
        # then the file's own order.
        def tie_breakers(node, words, stopped)
          name = node["name"].to_s.split(" > ").last.to_s.downcase.split(/[^\p{Alpha}]+/)
                             .select { |word| word.length >= Classifier::MIN_WORD_LENGTH }
          covered = name.count { |part| words.any? { |word| Classifier.word_match?(word, part) } }
          generic = name.any? { |part| stopped.key?(part) } ? 1 : 0
          [-covered.fdiv([name.length, 1].max), generic, Array(node["keywords"]).length, node["order"]]
        end

        # @return [Array<String>] ids of the nodes in `index` with a keyword
        #   `word` matches.
        def matching_ids(word, index)
          keywords_matching(word).flat_map { |keyword| index.fetch(keyword, []) }.uniq
        end

        # The keywords Classifier.word_match? accepts `word` for: itself, the
        # singular it is a plural of ("boots" -> "boot", "watches" ->
        # "watch"), the plural of it ("boot" -> "boots"), and the "y"/"ies"
        # swap. Looking a word's few candidate keywords up in a hash, rather
        # than comparing every word with every keyword, keeps a long
        # product-tag text (Index::Sources::StorefrontProducts,
        # docs/plans/local-catalogue.md Phase 2) cheap now that nodes carry
        # hundreds of keywords.
        def keywords_matching(word)
          keywords = [word, "#{word}s", "#{word}es"]
          keywords << word.delete_suffix("s") if word.end_with?("s")
          keywords << word.delete_suffix("es") if word.end_with?("es")
          keywords << "#{word[0..-4]}y" if word.end_with?("ies")
          keywords << "#{word[0..-2]}ies" if word.end_with?("y")
          keywords
        end
      end
    end
  end
end

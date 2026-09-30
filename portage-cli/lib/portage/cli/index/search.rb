require "uri"

module Portage
  module Cli
    module Index
      # The SQL behind ProductStore#search: an FTS5 MATCH over products_fts
      # (Index::Schema) ranked by bm25, or the same filters as a LIKE scan
      # when the database has no FTS table.
      module Search
        # bm25 weights for products_fts's columns: key (unindexed), title,
        # brand, category, aliases. A title hit outranks a brand-only one.
        BM25 = "bm25(products_fts, 0.0, 10.0, 3.0, 1.0, 5.0)".freeze
        LIKE_COLUMNS = %w[$.title $.brand $.category $.aliases].freeze
        HOST_LIKE = Array.new(4) { "s.origin LIKE ?" }.join(" OR ").freeze

        module_function

        # Letters and digits only, so nothing the user types is FTS5 syntax.
        # A trailing plural ending is dropped and each word matched as a
        # prefix, so "lights" finds "Light" and "Lighting".
        def words(query)
          query.to_s.downcase.scan(/\p{Alnum}+/).map { |w| w.length > 3 ? w.sub(/(?:ies|es|s)\z/, "") : w }
        end

        def host_of(store)
          return nil if store.to_s.strip.empty?

          text = store.to_s.strip
          (text.include?("://") ? URI.parse(text).host : text.split(%r{[/?]}).first).to_s.downcase
        rescue URI::InvalidURIError
          text.downcase
        end

        # @return [Array(String, Array)] sql and binds.
        def sql(words, category:, host:, limit:, fts:)
          match_sql, binds = fts ? fts_match(words) : like_match(words)
          filters = [match_sql]
          if category
            filters << "json_extract(p.data, '$.category') = ?"
            binds << category.to_s
          end
          if host
            filters << "EXISTS (SELECT 1 FROM product_stores s WHERE s.key = p.key AND (#{HOST_LIKE}))"
            binds.concat(host_patterns(host))
          end
          [select(fts, filters.join(" AND ")), binds + [limit.to_i]]
        end

        # The host itself or any subdomain of it, with or without a port —
        # so `--store jbhifi.com.au` finds https://www.jbhifi.com.au.
        def host_patterns(host) = ["%://#{host}", "%://#{host}:%", "%.#{host}", "%.#{host}:%"]

        def select(fts, where)
          if fts
            "SELECT p.data FROM products_fts JOIN products p ON p.id = products_fts.rowid " \
              "WHERE #{where} ORDER BY #{BM25} LIMIT ?"
          else
            "SELECT p.data FROM products p WHERE #{where} ORDER BY p.id LIMIT ?"
          end
        end

        def fts_match(words)
          ["products_fts MATCH ?", [words.map { |w| %("#{w}"*) }.join(" ")]]
        end

        def like_match(words)
          any_column = LIKE_COLUMNS.map { |path| "lower(json_extract(p.data, '#{path}')) LIKE ?" }.join(" OR ")
          [words.map { "(#{any_column})" }.join(" AND "), words.flat_map { |w| ["%#{w}%"] * LIKE_COLUMNS.length }]
        end
      end
    end
  end
end

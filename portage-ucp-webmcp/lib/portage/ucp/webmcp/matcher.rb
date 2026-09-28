module Portage
  module Ucp
    module WebMcp
      # The Phase 2 fallback for a page `Presets.detect` doesn't recognize
      # (docs/plans/webmcp-universal-outbound.md): proposes a `tool_names:`
      # mapping from what the page's own tools *look like* — their names,
      # tokenized and compared to each UCP action's own name; their input
      # schema's property shape; and their `readOnlyHint` annotation.
      #
      # Deliberately never reads a tool's `description`: that's page text,
      # the same untrusted-content boundary Presets draws (see its module
      # comment) — a page could name a mutating tool `search_catalog` and
      # write a friendly description, and nothing here would be fooled by
      # either, because neither is consulted for scoring or for the
      # `tool_names` this method returns.
      #
      # No LLM lives in this gem. A caller free to run its own matching
      # (an agent with a model already in the loop) can just build a
      # `tool_names:` hash directly and skip this — see the `shop-via-ucp`
      # skill. This is the deterministic fallback for a caller with none.
      #
      # A proposal is not a mapping: nothing here calls a tool, prompts
      # anyone, or persists anything. That's `portage-cli`'s job — it also
      # enforces the confirm-before-mutate rule this method's docstring
      # below leans on (`Portage::Cli::WebmcpMappingConfirm`,
      # `Portage::Cli::WebmcpMappings`).
      module Matcher
        # @!attribute tool [String] the page's own tool name this action was
        #   matched to.
        # @!attribute confidence [Float] 0.0-1.0, weighted from name-token
        #   overlap, input-schema shape and readOnlyHint agreement.
        # @!attribute reason [String] plain-language explanation — never
        #   quotes the tool's own description (see module comment).
        Proposal = Struct.new(:tool, :confidence, :reason, keyword_init: true)

        Candidate = Struct.new(:tokens, :read_only, :shape, keyword_init: true)

        # Weighted the way the module comment orders its evidence: what the
        # tool is *called* matters most, what its *schema* looks like next,
        # and the *hint* — often absent altogether — least.
        WEIGHTS = { name: 0.5, shape: 0.35, read_only: 0.15 }.freeze

        # Below this, a "match" is closer to noise than a proposal — every
        # action stays unmapped rather than offering a guess nobody should
        # trust, confirmed or not.
        MIN_CONFIDENCE = 0.3

        def self.candidate(tokens, read_only:, &shape)
          Candidate.new(tokens: tokens, read_only: read_only, shape: shape)
        end
        private_class_method :candidate

        # One entry per UCP action this gem's Session can drive over WebMCP
        # (Transport#candidates_for's own action names). `update_checkout`/
        # `complete_checkout`/order actions aren't included: WebMCP checkout
        # is hand-off-only today (see docs/plans/webmcp-universal-outbound.md
        # Context, "Checkout stays a hand-off"), so there's nothing for a
        # matched `create_checkout` to be followed by yet.
        CANDIDATES = {
          "search_catalog" => candidate(%w[search find catalog products query lookup browse],
                                        read_only: true) do |props|
            props.include?("query")
          end,
          "get_product" => candidate(%w[get product item detail show fetch], read_only: true) do |props|
            props.intersect?(%w[product_id id]) && !props.include?("quantity")
          end,
          "get_cart" => candidate(%w[get cart view fetch], read_only: true) do |props|
            props.intersect?(%w[cart_id id]) && !props.include?("quantity")
          end,
          "create_cart" => candidate(%w[add cart create], read_only: false) do |props|
            (props & %w[product_id variant_id quantity]).size >= 2
          end,
          "update_cart" => candidate(%w[update cart change modify lines], read_only: false) do |props|
            props.include?("line_items") || (props.include?("cart_id") && props.include?("quantity"))
          end,
          "create_checkout" => candidate(%w[checkout create start begin proceed], read_only: false) do |props|
            props.include?("line_items")
          end
        }.freeze

        # @param tools [Array<Hash>] as Bridge#list_tools/Transport#tools
        #   returns them.
        # @return [Hash{String => Proposal}] one entry per action a tool
        #   scored above MIN_CONFIDENCE against — an action with no
        #   plausible match on this page is simply absent, not given a weak
        #   guess.
        def self.propose(tools)
          CANDIDATES.each_with_object({}) do |(action, candidate), proposals|
            best = best_match(candidate, tools)
            proposals[action] = best if best
          end
        end

        # @param proposal [Hash{String => Proposal}] as .propose returns.
        # @return [Hash{String => String}] action => tool name, the shape
        #   `tool_names:` itself takes.
        def self.tool_names(proposal) = proposal.transform_values(&:tool)

        def self.best_match(candidate, tools)
          tools.filter_map { |tool| score(candidate, tool) }.max_by(&:confidence)
        end
        private_class_method :best_match

        def self.score(candidate, tool)
          name = (tool["name"] || tool[:name]).to_s
          return nil if name.empty?

          overlap = tokenize(name) & candidate.tokens
          return nil if overlap.empty?

          name_score = overlap.size.to_f / candidate.tokens.size
          properties = input_properties(tool)
          shape_match = candidate.shape.call(properties)
          read_only_hint = read_only_hint_of(tool)

          confidence = weighted_confidence(name_score, shape_match, candidate.read_only, read_only_hint)
          return nil if confidence < MIN_CONFIDENCE

          Proposal.new(tool: name, confidence: confidence.round(2),
                       reason: reason_for(overlap, shape_match, candidate.read_only, read_only_hint))
        end
        private_class_method :score

        def self.weighted_confidence(name_score, shape_match, expected_read_only, read_only_hint)
          read_only_score = if read_only_hint.nil?
                              0.5
                            else
                              read_only_hint == expected_read_only ? 1.0 : 0.0
                            end
          (WEIGHTS[:name] * name_score) + (WEIGHTS[:shape] * (shape_match ? 1.0 : 0.0)) +
            (WEIGHTS[:read_only] * read_only_score)
        end
        private_class_method :weighted_confidence

        def self.reason_for(overlap, shape_match, expected_read_only, read_only_hint)
          parts = ["name shares #{overlap.sort.join(', ')}"]
          parts << "input schema matches the expected shape" if shape_match
          parts << "readOnlyHint (#{read_only_hint.inspect}) agrees" if read_only_hint == expected_read_only
          parts << "readOnlyHint (#{read_only_hint.inspect}) disagrees" if !read_only_hint.nil? &&
                                                                           read_only_hint != expected_read_only
          parts.join("; ")
        end
        private_class_method :reason_for

        def self.input_properties(tool)
          schema = tool["inputSchema"] || tool[:inputSchema] || {}
          properties = schema["properties"] || schema[:properties] || {}
          properties.keys.map(&:to_s)
        end
        private_class_method :input_properties

        def self.read_only_hint_of(tool)
          annotations = tool["annotations"] || tool[:annotations]
          return nil unless annotations

          value = annotations.key?("readOnlyHint") ? annotations["readOnlyHint"] : annotations[:readOnlyHint]
          value.nil? ? nil : !!value
        end
        private_class_method :read_only_hint_of

        # camelCase and snake_case alike, e.g. "findProducts" -> %w[find
        # products], "search_catalog" -> %w[search catalog].
        def self.tokenize(name)
          name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').split(/[_\-\s]+/).map(&:downcase).reject(&:empty?)
        end
        private_class_method :tokenize
      end
    end
  end
end

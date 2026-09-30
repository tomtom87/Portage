module Portage
  module Cli
    module Index
      module Sources
        class StorefrontProducts
          # Just enough robots.txt (RFC 9309) to answer "may this agent GET
          # this path?": the group naming this agent if there is one, else
          # the `*` group; `*` and `$` in rules; the longest matching rule
          # wins, and Allow wins a tie. No rules, or no file, means allowed.
          class Robots
            def initialize(body)
              @groups = parse(body.to_s)
            end

            # @param path [String] request path, query included.
            # @param agent [String] the User-Agent this process sends.
            def allowed?(path, agent:)
              rules = rules_for(agent.to_s.downcase)
              matches = rules.select { |_allow, pattern| match?(pattern, path) }
              return true if matches.empty?

              longest = matches.map { |_allow, pattern| pattern.length }.max
              matches.select { |_allow, pattern| pattern.length == longest }.any?(&:first)
            end

            private

            def rules_for(agent)
              named = @groups.select { |agents, *| agents.any? { |a| a != "*" && agent.include?(a) } }
              chosen = named.empty? ? @groups.select { |agents, *| agents.include?("*") } : named
              chosen.flat_map { |_agents, rules, _closed| rules }
            end

            # @return [Array<Array>] [agents, [[allow?, pattern], ...], closed]
            #   per group.
            def parse(body)
              groups = []
              body.each_line do |line|
                field, value = line.sub(/#.*/, "").split(":", 2).map { |part| part.to_s.strip }
                next if value.nil?

                add_line(groups, field.downcase, value)
              end
              groups
            end

            # A rule line (even an empty `Disallow:`) ends a group's
            # User-agent list, so the next User-agent starts a new group.
            def add_line(groups, field, value)
              if field == "user-agent"
                groups << [[], [], false] if groups.empty? || groups.last[2]
                groups.last[0] << value.downcase
              elsif %w[allow disallow].include?(field) && groups.any?
                groups.last[2] = true
                groups.last[1] << [field == "allow", value] unless value.empty?
              end
            end

            def match?(pattern, path)
              anchored = pattern.end_with?("$")
              body = anchored ? pattern.chomp("$") : pattern
              regex = body.split("*", -1).map { |part| Regexp.escape(part) }.join(".*")
              Regexp.new("\\A#{regex}#{'\\z' if anchored}").match?(path)
            end
          end
        end
      end
    end
  end
end

require "yaml"

module Portage
  module Cli
    module Classifier
      # The shipped categories.yml and the user's ~/.portage/categories.yml,
      # merged (a user node replaces a shipped node of the same id), with the
      # keyword => node ids indexes the scoring looks words up in.
      Table = Struct.new(:nodes, :own, :parent)

      class Table
        @cache = {}

        class << self
          # Built once per pair of files and kept for the process, keyed by
          # the files' mtime and size, so an edit to ~/.portage/categories.yml
          # still shows up on the next call; classifying a whole catalogue
          # would otherwise rebuild the index for every product.
          def for(known_path, user_path)
            key = [signature(known_path), signature(user_path)]
            @cache.clear if @cache.size > 8
            @cache[key] ||= build(known_path, user_path)
          end

          # @return [Hash] the YAML mapping at `path`; empty when the file is
          #   missing, unreadable or not a mapping.
          def load_yaml(path)
            return {} unless path && File.readable?(path)

            data = YAML.safe_load_file(path)
            data.is_a?(Hash) ? data : {}
          rescue StandardError
            {}
          end

          private

          def build(known_path, user_path)
            ordered = {}
            load_yaml(known_path).each_with_index { |(id, node), i| ordered[id] = node.merge("order" => i) }
            load_yaml(user_path).each_with_index do |(id, node), i|
              ordered[id] = node.merge("order" => ordered.size + i)
            end
            new(ordered, index(ordered, "keywords"), index(ordered, "parent_keywords"))
          end

          def index(nodes, field)
            result = Hash.new { |hash, key| hash[key] = [] }
            nodes.each { |id, node| Array(node[field]).each { |keyword| result[keyword] << id } }
            result.default_proc = nil
            result
          end

          def signature(path)
            return nil unless path && File.readable?(path)

            [path, File.mtime(path).to_r, File.size(path)]
          end
        end
      end
    end
  end
end

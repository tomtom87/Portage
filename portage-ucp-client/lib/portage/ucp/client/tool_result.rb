require "json"

module Portage
  module Ucp
    module Client
      # Normalizes a tools/call JSON-RPC response into either the tool's
      # structuredContent, or a raised ServerError — shared across transports
      # since the loopback transport gets a symbol-keyed response (no JSON
      # round-trip, see Transports::Loopback) while stdio/HTTP get a
      # string-keyed one (real wire JSON, parsed by the `mcp` gem's client).
      module ToolResult
        def self.extract(response, symbol_keys:)
          result = fetch(response, "result", symbol_keys) || {}
          content = fetch(result, "content", symbol_keys)
          if fetch(result, "isError", symbol_keys)
            body = text(content, symbol_keys: symbol_keys)
            raise ServerError.new(body, payload: parse(body))
          end

          fetch(result, "structuredContent", symbol_keys)
        end

        def self.text(content, symbol_keys:)
          Array(content).filter_map { |block| fetch(block, "text", symbol_keys) }.join(" ")
        end

        # A UCP server's error text is usually its whole JSON error document
        # (see ServerError) — parsed here so callers get the `messages[]` and
        # `continue_url` inside it without re-parsing a string. Anything that
        # isn't a JSON object stays nil and callers fall back to the raw text.
        def self.parse(body)
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end
        private_class_method :parse

        def self.fetch(hash, key, symbol_keys)
          hash[symbol_keys ? key.to_sym : key]
        end
        private_class_method :fetch
      end
    end
  end
end

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
          raise ServerError, text(content, symbol_keys: symbol_keys) if fetch(result, "isError", symbol_keys)

          fetch(result, "structuredContent", symbol_keys)
        end

        def self.text(content, symbol_keys:)
          Array(content).filter_map { |block| fetch(block, "text", symbol_keys) }.join(" ")
        end

        def self.fetch(hash, key, symbol_keys)
          hash[symbol_keys ? key.to_sym : key]
        end
        private_class_method :fetch
      end
    end
  end
end

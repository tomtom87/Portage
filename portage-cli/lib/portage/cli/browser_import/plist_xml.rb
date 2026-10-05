require "strscan"
require "cgi/escape"

module Portage
  module Cli
    module BrowserImport
      # Just enough of Apple's XML property-list format to read Safari's
      # Bookmarks.plist once `plutil -convert xml1` has turned its binary
      # form into XML. `plutil -convert json` would be simpler but refuses
      # any plist holding a <date> (Safari's Reading List entries carry
      # them), and a real XML library (rexml) isn't a runtime dependency of
      # this gem — this is ~50 lines instead of a new one. Entities go
      # through CGI.unescapeHTML from `cgi/escape`, a default library.
      #
      # Dates, data and numbers come back as their raw text; bookmark
      # import only ever reads strings out of the tree.
      module PlistXml
        class ParseError < StandardError; end

        SCALARS = "string|key|data|date|integer|real".freeze

        def self.parse(xml)
          scanner = StringScanner.new(xml.to_s)
          raise ParseError, "not an XML plist" unless scanner.skip_until(/<plist[^>]*>/)

          value(scanner)
        end

        def self.value(scanner)
          scanner.skip(/\s*/)
          if scanner.scan(%r{<(dict|array|#{SCALARS})\s*/>}) then empty(scanner[1])
          elsif scanner.scan(%r{<(true|false)\s*/>}) then scanner[1] == "true"
          elsif scanner.scan("<dict>") then dict(scanner)
          elsif scanner.scan("<array>") then array(scanner)
          elsif scanner.scan(%r{<(#{SCALARS})>(.*?)</\1>}m) then CGI.unescapeHTML(scanner[2])
          else raise ParseError, "unexpected plist content at #{scanner.pos}"
          end
        end

        def self.dict(scanner)
          result = {}
          until scanner.skip(%r{\s*</dict>})
            key = value(scanner)
            raise ParseError, "dict key isn't a string" unless key.is_a?(String)

            result[key] = value(scanner)
          end
          result
        end

        def self.array(scanner)
          result = []
          result << value(scanner) until scanner.skip(%r{\s*</array>})
          result
        end

        def self.empty(tag)
          { "dict" => {}, "array" => [] }.fetch(tag, "")
        end

        private_class_method :value, :dict, :array, :empty
      end
    end
  end
end

require "uri"

require_relative "../../search_backends"

module Portage
  module Cli
    module Index
      module Sources
        # The user's own `~/.portage/stores.yml` (or `PORTAGE_STORES`) —
        # already-trusted stores they listed themselves. Reuses
        # SearchBackends::Allowlist's own parsing (env + file, bare URL or
        # `{url:, categories:}`) rather than re-reading the file, so a
        # change to that format only has to be made in one place.
        class StoresFile
          def initialize(allowlist: SearchBackends::Allowlist.new)
            @allowlist = allowlist
          end

          def name = "stores_file"

          def description
            "Your own ~/.portage/stores.yml / PORTAGE_STORES — stores you've already trusted directly."
          end

          def source_path = SearchBackends::Allowlist::PATH

          # @return [Array<Hash>] one sighting per store, no product
          #   identity (stores.yml only ever names a store, never a
          #   product). `**` accepts (and ignores) the shared
          #   Source#candidates(queries:) interface — stores.yml has no
          #   query of its own to run.
          def candidates(**)
            @allowlist.stores.filter_map { |entry| sighting_for(entry[:url]) }
          end

          private

          def sighting_for(url)
            origin = origin_of(url)
            return nil unless origin

            { origin: origin, url: nil, title: nil, brand: nil, gtin: nil }
          end

          def origin_of(url)
            uri = URI.parse(url.to_s)
            return nil unless uri.host && uri.scheme.to_s.start_with?("http")

            port = uri.port == uri.default_port ? "" : ":#{uri.port}"
            "#{uri.scheme}://#{uri.host}#{port}"
          rescue URI::InvalidURIError
            nil
          end
        end
      end
    end
  end
end

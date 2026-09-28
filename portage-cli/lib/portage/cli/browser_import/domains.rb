require "uri"

module Portage
  module Cli
    module BrowserImport
      # Reduces Readers rows to domains — the only thing about a row an
      # import keeps past this point, besides the page title/folder/slug
      # words Categorize reads locally. `www.` is folded into the bare
      # domain, and anything that isn't an http(s) URL with a host
      # (`chrome://`, `file:`, `about:`, `javascript:`) is dropped.
      module Domains
        # @return [Hash{String => Hash}] domain => { hosts: {host => visits},
        #   rows: [...], visits: total }.
        def self.group(rows)
          groups = {}
          rows.each do |row|
            host = host_of(row[:url])
            next unless host

            group = (groups[host.delete_prefix("www.")] ||= { hosts: Hash.new(0), rows: [], visits: 0 })
            group[:hosts][host] += row[:visits]
            group[:rows] << row
            group[:visits] += row[:visits]
          end
          groups
        end

        # The most-visited host variant (www. or not) as an https origin —
        # UCP is https-only, so an http-only visit still probes https.
        def self.origin_for(group) = "https://#{group[:hosts].max_by { |_h, visits| visits }.first}"

        # An index entry's origin, reduced the same way, so it compares
        # against a group's key.
        def self.key_of(origin) = host_of(origin)&.delete_prefix("www.")

        def self.host_of(url)
          uri = URI.parse(url.to_s)
          return nil unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty?

          uri.host.downcase
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end

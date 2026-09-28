require "uri"
require_relative "config"

module Portage
  module Cli
    # Tier C (docs/plans/buy-skill-and-local-browser.md Phase 5): the single
    # place that decides whether a host is hand-off only — Amazon (every
    # marketplace) by default, plus whatever the user adds or removes in
    # ~/.portage/config.json's "handoff_only_hosts". `Buy#call`, `Find`,
    # `Index::Builder` and `BrowserImport::Importer` all read this list
    # (Importer already had an injectable `handoff_only_hosts:` seam for it)
    # rather than each hard-coding or re-deriving their own — the one
    # invariant every caller depends on is "never probed, never fetched,
    # never automated", and that only holds if there's exactly one place
    # deciding host membership.
    #
    # Absent key: the shipped default list. Present key (even an empty
    # array): the user's list *is* the list — they can drop Amazon entirely
    # or add other hosts, and #host? only ever consults what #hosts returns.
    class HandoffOnly
      CONFIG_KEY = "handoff_only_hosts".freeze

      # Every Amazon marketplace TLD, current as of this phase — the user's
      # own config.json list can extend or shrink this once it's present.
      DEFAULT_HOSTS = %w[
        amazon.com amazon.co.uk amazon.de amazon.fr amazon.it amazon.es amazon.nl amazon.se amazon.pl
        amazon.com.be amazon.ie amazon.ca amazon.com.mx amazon.com.br amazon.co.jp amazon.in amazon.com.au
        amazon.sg amazon.ae amazon.sa amazon.eg amazon.com.tr amazon.cn
      ].freeze

      # Facts, not legal advice (docs/plans/buy-skill-and-local-browser.md
      # decision 5): what the site's terms say, plus the as-is/no-warranty
      # line. Reused verbatim by Buy's `handoff_only` report, `doctor`,
      # `portage setup`'s wizard, and the `buy` skill's own reference doc.
      LEGAL_NOTICE = "This retailer's terms restrict automated purchasing agents, so Portage opens the page " \
                     "and you complete the purchase. Portage is open-source software provided as-is, " \
                     "without warranty.".freeze

      def initialize(config: Config.load)
        @config = config
      end

      # @return [Array<String>] lowercase base hosts (no scheme, no path,
      #   no "www."). A user entry of "www.example.com", "example.com/",
      #   or "https://www.example.com/s?k=x" all normalize to the same
      #   "example.com" — the same normalization
      #   `BrowserImport::Importer`/`Domains` already apply to a history or
      #   bookmark domain, so a host written any of those ways behaves the
      #   same everywhere it's checked.
      def hosts
        configured = @config.get(CONFIG_KEY)
        return DEFAULT_HOSTS unless configured.is_a?(Array)

        configured.filter_map { |h| self.class.normalize_entry(h) }
      end

      # @param host [String, nil] a bare hostname, e.g. "www.amazon.co.uk".
      def host?(host) = self.class.matches_any?(host, hosts)

      # Amazon-ness is a fact about the domain, independent of whatever the
      # user's own config currently lists (they may have removed it from
      # #hosts and still be on an amazon.* origin) — used by Buy to decide
      # whether it knows a search/cart-add URL pattern for this host at all.
      def self.amazon?(host) = matches_any?(host, DEFAULT_HOSTS)

      def self.matches_any?(host, list)
        normalized = host.to_s.downcase.strip
        return false if normalized.empty?

        list.any? { |base| normalized == base || normalized.end_with?(".#{base}") }
      end

      # A bare host ("amazon.co.uk"), one already carrying "www." ("www.
      # amazon.co.uk"), or a full URL a user pasted in ("https://www.
      # amazon.co.uk/s?k=x") — a scheme means this is a URL, parsed for its
      # host; otherwise it's a bare host/host-with-path, so only the part
      # before the first "/" or "?" counts.
      def self.normalize_entry(value)
        text = value.to_s.strip
        return nil if text.empty?

        host = text.include?("://") ? uri_host(text) : text[%r{\A[^/?\s]+}]
        host = host.to_s.downcase.delete_prefix("www.")
        host.empty? ? nil : host
      end

      def self.uri_host(text)
        URI.parse(text).host
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

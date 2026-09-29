require "uri"
require_relative "browser_opener"

module Portage
  module Cli
    # Opens the store's page for an offer or quote, so the person can look
    # before they pick or approve (docs/plans/human-pick-and-approve.md
    # Phase 2, "View the product page"). Used by `pick --view`, `approve
    # --view` and the `v`/`v N` answers at a tty prompt. Never gated by the
    # auto-open setting: the person asked for this page by name.
    #
    # The URL came from the store, so it's untrusted: only an http(s) URL on
    # the offer's own store host is opened, and anything else is refused
    # with `view_refused` rather than handed to the OS opener.
    #
    # Host rule: the URL's host must equal the store's host, compared
    # case-insensitively with one leading `www.` ignored on either side
    # (`shop.example` and `www.shop.example` are the same shop). Any other
    # subdomain (`cdn.shop.example`, `shop.example.evil.test`) is refused —
    # a store that keeps product pages on another host just can't be
    # viewed from here. A URL carrying credentials (`user@host`) is refused
    # too.
    class ProductPage
      include BrowserOpener

      # @param url [String, nil] the product page as find/compare returned it.
      # @param store [String] the offer's store origin (or a bare host).
      def initialize(url:, store:)
        @url = url
        @store = store
      end

      # @return [Hash] `outcome: "viewed"` (with `opened:`) or
      #   `outcome: "view_refused"` (with the reason as `message:`).
      def open
        reason = refusal
        return { outcome: "view_refused", url: @url, store: @store, message: reason } if reason

        opened = open_browser(@url)
        { outcome: "viewed", url: @url, opened: opened,
          message: opened ? "Opened #{@url}." : "Couldn't open a browser — the page is #{@url}" }
      end

      # @return [String, nil] why the page can't be opened, nil when it can.
      def refusal
        return "No product page on record for this offer." if @url.to_s.strip.empty?

        uri = web_uri(@url)
        return "Not an http(s) URL: #{@url}" unless uri
        return "Refusing a URL with credentials in it: #{@url}" if uri.userinfo
        return nil if self.class.same_shop?(uri.host, store_host)

        "#{uri.host} isn't the offer's store (#{store_host || @store}) — not opening #{@url}"
      end

      def self.same_shop?(host, store_host)
        return false unless host && store_host

        host_key(host) == host_key(store_host)
      end

      def self.host_key(host) = host.downcase.delete_prefix("www.")
      private_class_method :host_key

      private

      def store_host
        raw = @store.to_s.strip
        parse(raw.match?(%r{\Ahttps?://}i) ? raw : "https://#{raw}")&.host
      end

      def web_uri(url)
        uri = parse(url)
        uri if uri&.host && %w[http https].include?(uri.scheme&.downcase)
      end

      def parse(url)
        URI.parse(url.to_s.strip)
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

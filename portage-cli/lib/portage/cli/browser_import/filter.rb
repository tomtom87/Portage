require "ipaddr"

require_relative "../search_backends"

module Portage
  module Cli
    module BrowserImport
      # "Is this host obviously not a shop?" — decided locally, before a
      # single probe is spent (docs/plans/buy-skill-and-local-browser.md
      # Phase 3: "skipping obvious non-shops (NON_STORE_HOSTS, webmail,
      # banks, intranet and localhost hosts)"). A skipped host never leaves
      # the machine at all, so these lists err on the side of skipping:
      # a missed shop costs one `portage index add`, a probed bank costs
      # the user's trust.
      module Filter
        WEBMAIL_HOSTS = %w[
          mail.google.com outlook.live.com outlook.office.com outlook.office365.com mail.yahoo.com
          proton.me protonmail.com icloud.com fastmail.com mail.aol.com gmx.com zoho.com
        ].freeze

        # Banks and payment/finance hosts are never a UCP storefront, and
        # are exactly the hosts a shopper least wants anything sent about.
        # Not exhaustive — backed up by BANK_WORD for the long tail.
        BANK_HOSTS = %w[
          paypal.com wise.com revolut.com monzo.com starlingbank.com chase.com wellsfargo.com
          citi.com capitalone.com americanexpress.com discover.com schwab.com fidelity.com vanguard.com
          hsbc.com hsbc.co.uk barclays.co.uk natwest.com santander.co.uk nationwide.co.uk halifax.co.uk
          coinbase.com kraken.com stripe.com klarna.com
        ].freeze

        BANK_WORD = /bank|creditunion/

        # Tools, social and media sites a shopper visits all day that will
        # never answer /.well-known/ucp — skipping them saves probes for
        # the domains that might.
        NON_SHOP_HOSTS = %w[
          github.com gitlab.com bitbucket.org stackoverflow.com stackexchange.com linkedin.com slack.com
          zoom.us notion.so atlassian.net figma.com claude.ai anthropic.com openai.com chatgpt.com
          instagram.com tiktok.com netflix.com spotify.com twitch.tv discord.com whatsapp.com
          medium.com substack.com apple.com microsoft.com live.com office.com gstatic.com
          googleusercontent.com cloudflare.com amazonaws.com
        ].freeze

        LOCAL_SUFFIXES = %w[localhost local internal lan corp home.arpa test intranet].freeze

        # @return [Symbol, nil] why `host` is skipped (:non_store, :webmail,
        #   :bank, :local), or nil when it's worth a probe.
        def self.skip_reason(host)
          host = host.to_s.downcase
          return :local if local?(host)
          return :webmail if webmail?(host)
          return :bank if bank?(host)
          return :non_store if non_store?(host)

          nil
        end

        def self.local?(host)
          return true if host.empty? || !host.include?(".")
          return true if ip?(host)

          LOCAL_SUFFIXES.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
        end

        def self.webmail?(host)
          host.start_with?("mail.", "webmail.") || matches?(host, WEBMAIL_HOSTS)
        end

        def self.bank?(host)
          matches?(host, BANK_HOSTS) || host.match?(BANK_WORD)
        end

        # SearchBackends::NON_STORE_HOSTS (search engines, Wikipedia,
        # social) plus this module's own NON_SHOP_HOSTS.
        def self.non_store?(host)
          !SearchBackends.store_candidate?("https://#{host}/") || matches?(host, NON_SHOP_HOSTS)
        end

        def self.matches?(host, list) = list.any? { |bad| host == bad || host.end_with?(".#{bad}") }

        def self.ip?(host)
          IPAddr.new(host.delete_prefix("[").delete_suffix("]"))
          true
        rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
          false
        end
        private_class_method :local?, :webmail?, :bank?, :non_store?, :matches?, :ip?
      end
    end
  end
end

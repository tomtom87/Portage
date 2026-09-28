module Portage
  module Cli
    # Where `find`/`buy`/`OfferSources::ShopifyCatalog` get
    # `meta.ucp-agent.profile` when the caller hasn't set
    # PORTAGE_AGENT_PROFILE.
    #
    # Real UCP servers fetch and verify that URL before answering any call
    # (Transports::Http), and the CLI used to read it via a bare
    # `ENV.fetch("PORTAGE_AGENT_PROFILE", nil)` with no fallback — a fresh
    # install that never copied `.env.example` got a bare
    # MissingAgentProfileError on its very first `find`/`buy`. The repo
    # already publishes its own profile document
    # (`portage-cli/agent-profile/agent-profile.json`) over jsdelivr, and
    # that URL is confirmed live against catalog.shopify.com (see
    # docs/agent-profile.md), so it's a reasonable "works enough to try it"
    # default — not a substitute for a caller hosting their own via
    # `portage generate agent-profile`.
    module AgentProfileUrl
      DEFAULT = "https://cdn.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/agent-profile/agent-profile.json"
                .freeze

      # @return [String] PORTAGE_AGENT_PROFILE, or DEFAULT when it's unset
      #   or blank.
      def self.resolve
        value = ENV.fetch("PORTAGE_AGENT_PROFILE", nil).to_s.strip
        value.empty? ? DEFAULT : value
      end
    end
  end
end

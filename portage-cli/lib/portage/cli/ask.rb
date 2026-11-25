require "portage/ucp"
require "portage/ucp/client"

require_relative "agent_profile_url"
require_relative "buy"
require_relative "find"
require_relative "handoff_host"
require_relative "user_agent"

module Portage
  module Cli
    # `portage ask <url> "question"` — put a question to a store through UCP's
    # `dev.ucp.common.ask` and print its answer (docs/plans/ucp-ask.md).
    #
    # Read-only on both sides: ask never changes a cart, checkout or order,
    # and nothing here acts on the answer, which is the store's own text and
    # is untrusted, like a product description. It is also no evidence that
    # anything happened: a store asked to "add two to my cart" says it didn't.
    #
    # Only called when the store advertises the capability; otherwise no ask
    # request is made and the outcome is `not_offered`. A hand-off-only host
    # is never fetched at all (HandoffHost, as `find --store`).
    class Ask
      ASK_CAP = "dev.ucp.common.ask".freeze

      # @param url [String] a store URL; Find.store_origin collapses it to its origin.
      # @param ids [Array<String>] the store's own ids (product, cart, order...) to ground the question in.
      # @param conversation [String, nil] an earlier answer's conversation id, to continue it.
      def initialize(url:, query:, ids: [], conversation: nil)
        @origin = Find.store_origin(url)
        @query = query.to_s
        @ids = ids
        @conversation = conversation
      end

      def call
        return report("handoff_only", handoff_only_message) if HandoffHost.restricted?(URI.parse(@origin).host)

        session = discover
        return report("error", "#{@origin} doesn't speak UCP, so there is nobody to ask.") unless session
        return report("not_offered", "#{@origin} doesn't offer ask.") unless session.advertises?(ASK_CAP)

        answered(session.ask(**request, meta: { agent_profile: AgentProfileUrl.resolve }))
      rescue Portage::Ucp::Client::MissingAgentProfileError
        report("error", "Set PORTAGE_AGENT_PROFILE to a URL that describes this agent — #{@origin} verifies " \
                        "it before answering any UCP call.")
      rescue Portage::Ucp::Client::ServerError => e
        store_error(e)
      rescue MCP::Client::RequestHandlerError => e
        report("error", "#{@origin} rejected the request (#{e.message}) — if PORTAGE_AGENT_PROFILE is set, " \
                        "check it points at a real agent-profile document the store accepts.")
      end

      private

      def request
        { query: @query, ids: (@ids if @ids.any?), conversation: @conversation && { id: @conversation } }
      end

      def discover
        Portage::Ucp::Client.discover(@origin, headers: UserAgent.headers)
      rescue Portage::Ucp::Client::DiscoveryError, Portage::Ucp::Client::ManifestShapeError
        nil
      end

      # AirShelf sends errors like capabilities_incompatible with HTTP 200 and
      # `ucp.status: "error"` (no answer), so the transport doesn't raise.
      def answered(wire)
        return wire_error(wire) if wire.dig("ucp", "status") == "error" || !wire["answer"]

        report("answered", nil, answer: wire["answer"], links: wire["links"] || [],
                                conversation: wire["conversation"], messages: wire["messages"] || [])
      end

      # The store's own code and text, as the catalog commands print them.
      def store_error(error)
        messages = Array(error.payload && error.payload["messages"])
        code = error.server_messages.filter_map { |m| m[:code] }.first
        report("error", "#{@origin} couldn't answer: #{Buy.server_error_text(error)}#{" (#{code})" if code}",
               messages: messages)
      end

      def wire_error(wire)
        messages = wire["messages"] || []
        error = messages.find { |m| m["type"] == "error" } || {}
        text = error["content"] || "no answer came back"
        report("error", "#{@origin} couldn't answer: #{text}#{" (#{error['code']})" if error['code']}",
               messages: messages)
      end

      def handoff_only_message
        "#{@origin} is a hand-off-only retailer: Portage never fetches it, so it wasn't asked. " \
          "Open the site yourself."
      end

      def report(outcome, message, **fields)
        { url: @origin, query: @query, ids: @ids, answer: nil, links: [], conversation: nil, messages: [],
          outcome: outcome, message: message }.merge(fields)
      end
    end
  end
end

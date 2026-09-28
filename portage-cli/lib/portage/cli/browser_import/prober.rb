require "timeout"
require "portage/ucp/client"

require_relative "../user_agent"
require_relative "../probe_cache"

module Portage
  module Cli
    module BrowserImport
      # The only way a browser-imported domain ever leaves this machine:
      # one `GET /.well-known/ucp` through Portage::Ucp::Client.discover
      # (the same discovery path `find` and `index build` use), recorded
      # in the shared ProbeCache so a domain that didn't answer last time
      # isn't asked again. No page, title, path or visit count is ever
      # sent — just the origin, as the host of that one request.
      class Prober
        THROTTLE = 0.1

        # Net::HTTP's own defaults are 60s each way — fine for one store,
        # not for 200 history domains, some of which will be dead hosts.
        TIMEOUT = 5

        # @param discover [#call, nil] `->(origin) { session_or_nil }` —
        #   injectable so specs never make a real request; nil (the
        #   default) uses Portage::Ucp::Client.discover.
        def initialize(cache: ProbeCache.new, discover: nil, throttle: THROTTLE, timeout: TIMEOUT)
          @cache = cache
          @discover = discover || method(:ucp_discover)
          @throttle = throttle
          @timeout = timeout
          @probes = 0
        end

        attr_reader :probes

        # A cached "no UCP here" verdict — answered with no request at all.
        def cached_miss?(origin) = @cache.fetch(origin) == false

        # @return [Portage::Ucp::Client::Session, nil]
        def probe(origin)
          sleep(@throttle) if @probes.positive? && @throttle.to_f.positive?
          @probes += 1
          session = safely { @discover.call(origin) }
          @cache.record(origin, !session.nil?)
          session
        end

        private

        def safely(&)
          Timeout.timeout(@timeout, &)
        rescue StandardError # Timeout::Error included
          nil
        end

        def ucp_discover(origin) = Portage::Ucp::Client.discover(origin, headers: UserAgent.headers)
      end
    end
  end
end

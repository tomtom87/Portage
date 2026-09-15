module Portage
  module Ucp
    module Journal
      # @abstract Pluggable append-only record store — same "no bundled
      #   storage assumption" posture as core's RateLimiter/Authenticator
      #   (portage-ucp §9), extended here to persistence (design-log §22).
      #   Unlike NullRateLimiter/UnconfiguredAuthenticator, there is no
      #   silent-no-op default: an unconfigured journal that drops every
      #   write defeats the point of a purchase record, so FileStore (this
      #   gem's own default) is a real, durable implementation, not a null
      #   object. The interface is deliberately minimal — append and replay
      #   only — because the only consumer today (PurchaseJournal) needs
      #   nothing more; extend it when a second real consumer (a console, a
      #   scheduler) needs keyed lookups, not speculatively ahead of one.
      class Store
        # @param record [Hash] a single journal entry, already built by the
        #   caller (PurchaseJournal). The store persists it as-is.
        def append(record)
          raise NotImplementedError, "#{self.class} must implement #append"
        end

        # Yields each previously-appended record, in write order, without a
        # block returns an Enumerator.
        def each_record(&)
          raise NotImplementedError, "#{self.class} must implement #each_record"
        end
      end
    end
  end
end

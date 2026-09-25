module Portage
  module Ucp
    module Support
      # Phase 3 of docs/plans/proxy-support.md: the fiber-local seam that
      # carries an inbound request's allowlisted passthrough headers (and
      # how to build the outbound `Forwarded`/`X-Forwarded-For` chain) to
      # Support::Connection, for outbound calls made while serving that
      # request.
      #
      # Fiber-local (`Fiber[]`, Ruby 3.2+ — the gem's own required_ruby_version),
      # not Thread.current, matching the plan's "fiber-local context" call
      # exactly: a single-threaded fiber-scheduled server (Falcon, the mcp
      # gem's own async transport) can run several requests concurrently on
      # one Thread but different Fibers, and Thread.current would leak one
      # request's passthrough headers into another running on the same
      # thread. Scoped with #with/ensure, same restore-on-the-way-out shape
      # CheckoutState.with_observability already uses for its own
      # per-request Thread.current slot — set once per inbound request, at
      # the Rack endpoint, and always cleared before that request finishes,
      # so nothing leaks into the next request/fiber.
      module PassthroughContext
        KEY = :portage_ucp_passthrough_headers

        # @param headers [Hash{String=>String}] already allowlist-filtered
        #   and protected-header-checked by the caller (see
        #   Rack::ForwardedRequest.validate_passthrough!/#passthrough_headers).
        # @param forwarded ["append", "replace", "drop"] how
        #   Support::Connection's outbound Forwarded/X-Forwarded-For chain
        #   should be built from `chain_entry` — "drop" (the default) never
        #   touches the outbound chain at all.
        # @param chain_entry [String, nil] this hop's own entry (the
        #   resolved client IP) to append/replace with; ignored when
        #   `forwarded` is "drop".
        def self.with(headers: {}, forwarded: "drop", chain_entry: nil)
          previous = Fiber[KEY]
          Fiber[KEY] = { headers: headers || {}, forwarded: forwarded.to_s, chain_entry: chain_entry }
          yield
        ensure
          Fiber[KEY] = previous
        end

        # @return [Hash, nil] the current fiber's context, or nil outside of
        #   any #with block (no request in flight, or a request from an
        #   untrusted peer / with nothing configured to pass through).
        def self.current
          Fiber[KEY]
        end

        def self.headers
          current&.fetch(:headers, {}) || {}
        end

        def self.forwarded_mode
          current&.fetch(:forwarded, "drop") || "drop"
        end

        def self.chain_entry
          current&.fetch(:chain_entry, nil)
        end
      end
    end
  end
end

require "json"
require "fileutils"
require "securerandom"
require "uri"
require "net/http"
require "portage/ucp"
require "portage/ucp/client"

# Buy::PermissiveAuthenticator (adapter-loopback auth) is used by
# #adapter_session below — not require_relative'd here to avoid a load
# cycle (buy.rb will require this file too, for PaymentMethods.default);
# cli.rb requires "cli/buy" before "cli/payment_methods", so it's already
# loaded by the time #enroll actually runs.
require_relative "payment_methods/keychain_backend"
require_relative "payment_methods/secret_service_backend"
require_relative "payment_methods/env_backend"
require_relative "user_agent"

module Portage
  module Cli
    # Card-on-file store for `portage buy`'s `--payment-token` dead-end
    # (buy.rb) — three backend tiers, picked once per process by
    # .detect_backend, no homegrown crypto or fallback file store of our
    # own (docs/plans/agentic-payments.md Phase 1):
    #
    #   1. macOS Keychain (KeychainBackend, shells out to `security`)
    #   2. Linux Secret Service (SecretServiceBackend, shells out to
    #      `secret-tool`) — only when a D-Bus session is actually live
    #   3. Headless (EnvBackend) — no local storage; the token comes
    #      straight from PORTAGE_PAYMENT_TOKEN
    #
    # The secret itself lives in the backend; this class only keeps
    # non-secret bookkeeping (label/default/frozen) in
    # ~/.portage/payment_methods.json — irrelevant for the headless tier,
    # which has no ids to track at all.
    #
    # Local policy guards agent mistakes, not a compromised agent: anyone
    # running as the local user can edit payment_methods.json directly, so
    # the real backstop against a rogue/compromised agent is an issuer-side
    # limit (a virtual card via Stripe Issuing, Privacy.com, etc.), not this
    # file.
    class PaymentMethods
      PATH = File.join(Dir.home, ".portage", "payment_methods.json").freeze

      class UnknownMethodError < StandardError; end

      def self.executable?(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, name)) && !File.directory?(File.join(dir, name))
        end
      end

      def self.detect_backend
        return KeychainBackend.new if KeychainBackend.available?
        return SecretServiceBackend.new if SecretServiceBackend.available?

        EnvBackend.new
      end

      def self.default(path: PATH, backend: detect_backend) = new(path: path, backend: backend).default

      def initialize(path: PATH, backend: self.class.detect_backend)
        @path = path
        @backend = backend
      end

      # @return [String, nil] the token `portage buy` should use when
      #   `--payment-token` was omitted, or nil if there isn't one it can
      #   safely use (nothing enrolled, or the only default is frozen).
      def default
        return @backend.read(nil) if headless?

        entry = store["methods"].find { |m| m["default"] }
        return nil if entry.nil? || entry["frozen"]

        @backend.read(entry["id"])
      end

      # @return [Array<Hash>] non-secret metadata only — never the token.
      def list
        return [] if headless?

        store["methods"]
      end

      def make_default(id)
        entry = find!(id)
        store["methods"].each { |m| m["default"] = (m["id"] == id) }
        write
        entry
      end

      # `remove` and `revoke` are the same hard delete (metadata entry +
      # backend secret, both gone) — the plan names them separately, but
      # with no processor-side "invalidate this token" capability to defer
      # to, there's no real distinction to invent between "remove" and
      # "delete the token" beyond the name. Both exist as CLI subcommands so
      # either reads naturally in the moment ("get rid of this" vs. "this
      # card's compromised, kill it").
      def remove(id)
        entry = find!(id)
        store["methods"].reject! { |m| m["id"] == id }
        write
        @backend.delete(id)
        entry
      end
      alias revoke remove

      # Blocks spend without forgetting the enrollment — `default` returns
      # nil for a frozen default, but the metadata entry (and backend
      # secret) stay put. No "unfreeze" — the plan draws the line at v1
      # only needing revoke to fully undo an enrollment.
      def freeze_method(id)
        entry = find!(id)
        entry["frozen"] = true
        write
        entry
      end

      # Starts a browser-handoff enrollment against `url` (native UCP
      # manifest, or the own-store adapter loopback — same discovery
      # buy.rb#call uses) and blocks polling
      # app.portage-ucp.payment_enrollment until the gateway-hosted setup
      # page resolves to a token or `timeout` elapses. Prints nothing
      # itself — callers (Cli.run_payment_enroll) own presentation.
      #
      # Yields the gateway-hosted `setup_url` to the given block as soon as
      # it's known (before polling starts) — the caller's one chance to show
      # it, since this method otherwise doesn't return until "complete" or
      # `timeout` elapses.
      #
      # @return [Hash] {status:, setup_url:, id:, label:} — status is
      #   "complete", "pending" (timed out — the CLI can re-poll later
      #   against the same enrollment id), or "unsupported" (nothing at
      #   `url` advertises payment enrollment).
      # @param scope [Hash, nil] Phase 2 per-token policy scope, bound at
      #   enrollment time (docs/plans/agentic-payments.md) — e.g.
      #   `{merchants: ["shop.example.com"], max_amount: 5000, currency: "USD"}`.
      #   Written to Portage::Ucp::Policy keyed by the same token_ref
      #   PolicyGuard derives from the token at charge time, never to
      #   payment_methods.json — policy config is portage-ucp's file, not
      #   this gem's.
      def enroll(url, label: nil, scope: nil, poll_interval: 3, timeout: 300, sleeper: ->(s) { sleep(s) })
        raise NotSupportedError, "headless mode has no local storage — set PORTAGE_PAYMENT_TOKEN instead" if headless?

        session = discover_session(url)
        return { status: "unsupported" } unless session && payment_enrollment_advertised?(session)

        enrollment = session.create_payment_enrollment
        yield enrollment["setup_url"] if block_given?
        poll_until_resolved(session, enrollment, label, scope, poll_interval, timeout, sleeper)
      rescue Portage::Ucp::Client::Error
        # Capability not actually there despite #advertises? being nil
        # (own-store adapter loopback doesn't know capabilities upfront —
        # see Session#advertises?) — the adapter simply never registered the
        # tool, surfaced as a client-side error rather than a Ruby NoMethodError.
        { status: "unsupported" }
      end

      private

      def headless?
        @backend.is_a?(EnvBackend)
      end

      def poll_until_resolved(session, enrollment, label, scope, poll_interval, timeout, sleeper)
        deadline = Time.now + timeout
        current = enrollment
        until current["status"] == "complete" || Time.now >= deadline
          sleeper.call(poll_interval)
          current = session.get_payment_enrollment(enrollment_id: current["id"])
          return { status: "unsupported" } unless current
        end
        return { status: "pending", setup_url: enrollment["setup_url"], id: enrollment["id"] } unless
          current["status"] == "complete"

        { status: "complete", **enroll_locally(current["payment_token"], label, scope) }
      end

      def enroll_locally(token, label, scope)
        id = SecureRandom.uuid
        @backend.write(id, token)
        entry = { "id" => id, "label" => label || id, "frozen" => false,
                  "default" => store["methods"].empty?, "created_at" => Time.now.utc.iso8601 }
        store["methods"] << entry
        write
        set_token_scope(token, scope) if scope
        { id: id, label: entry["label"] }
      end

      def set_token_scope(token, scope)
        token_ref = Portage::Ucp::Support::TokenRef.for(token)
        Portage::Ucp::Policy.load.set_token_scope(token_ref, stringify_keys(scope))
      end

      def stringify_keys(hash) = hash.transform_keys(&:to_s)

      # Same native-manifest-first, own-store-adapter-fallback discovery as
      # Buy#call — duplicated rather than extracted since Buy's version is
      # entangled with cart/checkout-specific branching this only needs the
      # session object from.
      def discover_session(url)
        native = Portage::Ucp::Client.discover(url, headers: UserAgent.headers)
        native if native
      rescue Portage::Ucp::Client::DiscoveryError
        adapter_session(url)
      end

      def adapter_session(url)
        uri = URI.parse(url.to_s =~ %r{\Ahttps?://}i ? url.to_s : "https://#{url}")
        body, headers = fetch_homepage(uri)
        platform = body && Portage::Ucp::Resolver.detect_platform(body, headers)
        return nil unless platform

        env = Portage::Ucp::Resolver.env_for(platform)
        return nil if Portage::Ucp::Resolver.missing_env(platform, env).any?

        adapter = Portage::Ucp::Resolver.build_adapter(platform, env)
        Portage::Ucp::Client.for_adapter(adapter, authenticator: Buy::PermissiveAuthenticator.new)
      rescue StandardError
        nil
      end

      def fetch_homepage(uri)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 5, read_timeout: 5) do |http|
          http.get(uri.request_uri, UserAgent.headers)
        end
        response.is_a?(Net::HTTPSuccess) ? [response.body, response.to_hash] : [nil, {}]
      rescue StandardError
        [nil, {}]
      end

      def payment_enrollment_advertised?(session)
        session.advertises?("app.portage-ucp.payment_enrollment") != false
      end

      def find!(id)
        store["methods"].find { |m| m["id"] == id } || raise(UnknownMethodError, id)
      end

      def store
        @store ||= read
      end

      def read
        parsed = File.readable?(@path) ? JSON.parse(File.read(@path)) : {}
        parsed = {} unless parsed.is_a?(Hash)
        { "methods" => Array(parsed["methods"]) }
      rescue StandardError
        { "methods" => [] }
      end

      # Unlike History#write, a failed write on the payment path is fatal
      # (docs/plans/agentic-payments.md's "transaction log writes are fatal
      # on the payment path" applies here too — a swallowed write here would
      # silently un-set/re-set a default or forget a freeze) — raises
      # rather than the `rescue StandardError; nil` pattern history.rb uses.
      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.generate(@store))
        File.chmod(0o600, @path)
      end
    end
  end
end

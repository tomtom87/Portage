require "json"
require "fileutils"

module Portage
  module Ucp
    # Local policy config for PolicyGuard (docs/plans/agentic-payments.md
    # Phase 2). File format is deliberately private/internal — `portage-ucp`
    # is a published gem, so PolicyGuard.check!'s keyword API is the stable
    # surface, not this schema, which can change across releases.
    #
    # Absent file, or an absent field within it, means "no restriction" for
    # that check — a fresh install doesn't block dispatch just because no
    # policy was ever configured. That's a deliberate default-permissive
    # choice: PolicyGuard.check! and Phase 3's Confirmer are two independent
    # layers, and confirmation defaults to *on* (Phase 1), so an unconfigured
    # policy isn't the only thing standing between an agent and a charge.
    #
    # A corrupt file is not the same as an absent one — that's data damage,
    # not "nothing configured" — so JSON parse errors raise rather than
    # silently falling back to permissive defaults.
    class Policy
      PATH = File.join(Dir.home, ".portage", "policy.json").freeze

      def self.load(path: PATH)
        new(path: path, data: read(path))
      end

      def initialize(path: PATH, data: {})
        @path = path
        @data = data
      end

      def per_transaction_cap = @data["per_transaction_cap"]
      def rolling_cap = @data["rolling_cap"]
      def velocity = @data["velocity"]
      def merchant_allowlist = Array(@data["merchant_allowlist"])
      def token_scope(token_ref) = (@data["token_scopes"] || {})[token_ref]

      # @param token_ref [String] from Support::TokenRef.for — bound at
      #   enrollment time (portage-cli's PaymentMethods#enroll), not per-call.
      def set_token_scope(token_ref, scope)
        @data["token_scopes"] ||= {}
        @data["token_scopes"][token_ref] = scope
        write
        scope
      end

      def set(key, value)
        @data[key.to_s] = value
        write
        value
      end

      def to_h = @data.dup

      def self.read(path)
        return {} unless File.readable?(path)

        raw = File.read(path)
        return {} if raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      end
      private_class_method :read

      private

      # Same "raise, don't swallow" convention as TransactionLog — a lost
      # write here means a cap/allowlist/scope change silently didn't take,
      # which is worse than the write never having been attempted.
      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(@data))
        File.chmod(0o600, @path)
      end
    end
  end
end

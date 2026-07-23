require "json"
require "base64"

module UcpMcp
  # Builds the /.well-known/ucp discovery document: protocol version, the
  # business's advertised capabilities (only those the Adapter overrides —
  # see Capability#advertised_for?), payment handlers, and signing keys.
  # Signing keys are never generated here — see §9, consumer-provided only.
  class Manifest
    UCP_VERSION = "2026-04-08".freeze

    # @param signer [#kid, #sign] optional. Consumer-provided — the gem never
    #   generates or stores keys itself (§9). `sign(canonical_json_string)`
    #   must return raw signature bytes; `kid` identifies which entry in
    #   `signing_keys` verifies it (supports a current+next key set for
    #   rotation — the caller picks which signer/kid pair is "current").
    #   Algorithm-agnostic by design: the gem doesn't dictate Ed25519 vs RSA.
    def initialize(adapter:, business:, registry: CapabilityRegistry.default,
                   payment_handlers: [], signing_keys: [], signer: nil)
      @adapter = adapter
      @business = business
      @registry = registry
      @payment_handlers = payment_handlers
      @signing_keys = signing_keys
      @signer = signer
    end

    def to_h
      payload = {
        ucp_version: UCP_VERSION,
        business: @business,
        capabilities: @registry.advertised(@adapter).map do |capability|
          { name: capability.name, version: capability.version }
        end,
        payment_handlers: @payment_handlers,
        signing_keys: @signing_keys
      }
      return payload unless @signer

      payload.merge(signature: sign(payload))
    end

    private

    def sign(payload)
      canonical = JSON.generate(payload)
      { kid: @signer.kid, value: Base64.strict_encode64(@signer.sign(canonical)) }
    end
  end
end

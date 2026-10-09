require "json"
require "base64"

module Portage
  module Ucp
    # Builds the /.well-known/ucp discovery document: protocol version, the
    # business's advertised capabilities (only those the Adapter overrides —
    # see Capability#advertised_for?), payment handlers, signing keys, and the
    # services array (transport + endpoint, e.g. {transport: "mcp", endpoint:
    # "https://..."}) a client needs to find where to actually connect.
    # Signing keys are never generated here — see §9, consumer-provided only.
    class Manifest
      UCP_VERSION = "2026-08-25".freeze

      # @param signer [#kid, #sign] optional. Consumer-provided — the gem never
      #   generates or stores keys itself (§9). `sign(canonical_json_string)`
      #   must return raw signature bytes; `kid` identifies which entry in
      #   `signing_keys` verifies it (supports a current+next key set for
      #   rotation — the caller picks which signer/kid pair is "current").
      #   Algorithm-agnostic by design: the gem doesn't dictate Ed25519 vs RSA.
      def initialize(adapter:, business: Portage::Ucp.configuration.business, registry: Portage::Ucp.configuration.registry,
                     payment_handlers: Portage::Ucp.configuration.payment_handlers,
                     signing_keys: Portage::Ucp.configuration.signing_keys, signer: Portage::Ucp.configuration.signer,
                     services: Portage::Ucp.configuration.services)
        @adapter = adapter
        @business = business
        @registry = registry
        @payment_handlers = payment_handlers
        @signing_keys = signing_keys
        @signer = signer
        @services = services
      end

      # Nests everything under a "ucp" envelope, and keys `capabilities` by
      # capability name. That is the shape live Shopify UCP rollouts (Casper,
      # Allbirds, Glossier, and 34+ others) serve under their own manifest
      # "version": "2026-08-25", and the shape portage-ucp-client's
      # Client.discover reads. As of 2026-08-25 the JWK Set is `keys` beside
      # `ucp` (not `ucp.signing_keys`) and every service entry needs a version.
      def to_h
        ucp = {
          version: UCP_VERSION,
          business: @business,
          services: @services.map { |service| { version: UCP_VERSION }.merge(service) },
          capabilities: capability_hash,
          payment_handlers: @payment_handlers
        }
        ucp = ucp.merge(signature: sign(ucp)) if @signer

        { ucp: ucp, keys: @signing_keys }
      end

      private

      def capability_hash
        @registry.advertised(@adapter).to_h { |capability| [capability.name, [{ version: capability.version }]] }
      end

      def sign(payload)
        canonical = JSON.generate(payload)
        { kid: @signer.kid, value: Base64.strict_encode64(@signer.sign(canonical)) }
      end
    end
  end
end

module UcpMcp
  # Adds the "ucp" response envelope UCP requires on Cart/Checkout/Order
  # payloads (schemas/ucp.json's response_cart_schema/response_checkout_schema/
  # response_order_schema) — centralized here so the version string and each
  # capability's minimum envelope shape live in one place, not duplicated
  # across value objects.
  module WireEnvelope
    SPEC_VERSION = "2026-04-08".freeze

    ENVELOPES = {
      "dev.ucp.shopping.cart" => -> { { "version" => SPEC_VERSION } },
      "dev.ucp.shopping.checkout" => -> { { "version" => SPEC_VERSION, "payment_handlers" => {} } },
      "dev.ucp.shopping.order" => -> { { "version" => SPEC_VERSION } }
    }.freeze

    def self.wrap(capability_name, payload_hash)
      envelope = ENVELOPES[capability_name]
      return payload_hash unless envelope

      payload_hash.merge("ucp" => envelope.call)
    end
  end
end

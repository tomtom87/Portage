require "openssl"
require "digest"
require "base64"
require "json"
require "fileutils"
require "portage/ucp"

module Portage
  module Cli
    module Generate
      # Generates and (re)publishes portage-cli's own UCP agent-identity
      # profile document — the `meta.ucp-agent.profile` URL real UCP servers
      # fetch and validate before answering any catalog/cart/checkout call
      # (confirmed live against Shopify's 2026-08-25 rollout: an unreachable
      # or malformed profile 422s with `profile_unreachable`/`profile_malformed`
      # before the request's shape is even considered). This class only
      # produces the document and its signing key; hosting it at a stable,
      # public URL (HTTPS, no redirects, `Cache-Control: public, max-age>=60`
      # — see docs/agent-profile.md) is a separate, one-time infra step.
      #
      # Deliberately NOT Portage::Ucp::Manifest, despite the surface
      # similarity: Manifest builds the *business's* /.well-known/ucp
      # document and nests `signing_keys` inside its own "ucp" envelope
      # (portage-ucp/lib/portage/ucp/manifest.rb); the UCP spec's agent
      # profile is a different document describing the *agent* calling in,
      # and puts `signing_keys` as a sibling of "ucp" at the document root.
      # Same-looking key material, structurally different document — not
      # interchangeable, so this doesn't subclass or reuse Manifest.
      #
      # The version here is deliberately *not* reused from
      # `Portage::Ucp::Manifest::UCP_VERSION`, unlike an earlier revision of
      # this class. Those two versions answer different questions: the
      # manifest's says which spec revision *this gem's own server* implements
      # for the businesses it serves, while an agent profile's says which
      # revision the agent speaks to *whichever remote store it dials*. A
      # store on a newer rollout than our server-side support (Shopify's
      # `2026-08-25` endpoints, today) negotiates against the profile, so
      # pinning the profile to the server's revision under-declared us.
      #
      # Rotation is the future-proofing this exists for: re-running with
      # `rotate: true` keeps every key already published (so a request
      # signed under an older `kid` keeps verifying while callers migrate)
      # and adds one freshly generated key alongside them. Nothing here ever
      # drops a key — retiring one is a deliberate, separate edit once
      # nothing signs with it any more.
      class AgentProfile
        UCP_VERSION = "2026-08-25".freeze

        SHOPPING_SERVICE = "dev.ucp.shopping".freeze

        Key = Struct.new(:kid, :jwk, :private_pem, keyword_init: true)

        # The capability identifiers a real UCP server resolves an incoming
        # agent's tool registry from. These are NOT
        # `Portage::Ucp::Capabilities::{CATALOG,CART,...}.name`, which an
        # earlier revision of this class reused, and that reuse is what broke
        # every live tool call for a month (see
        # docs/ucp-tool-gating-investigation.md):
        #
        # - Catalog is registered per *action*
        #   (`dev.ucp.shopping.catalog.search`, `.catalog.lookup`), not as one
        #   coarse `dev.ucp.shopping.catalog`. A profile declaring only the
        #   coarse name resolves to zero catalog tools, and the server then
        #   answers `search_catalog` with `-32602 Tool not found:
        #   search_catalog` — despite `tools/list` having advertised it
        #   seconds earlier, and with no hint that the profile is the reason.
        #   `Portage::Ucp::Capabilities::CATALOG` keeps the coarse name
        #   because that's the right shape for *our own* server's manifest,
        #   where one Capability object owns all three actions; the two
        #   registries simply don't line up, so this document spells its own
        #   ids out rather than deriving them.
        # - Cart/Checkout/Order are registered at the root name, so those do
        #   match — spelled out here anyway, so the whole declared set reads
        #   from one place.
        # - Versions are spec revisions (`2026-08-25`), not the `"1"` that
        #   `Capability#version` carries.
        #
        # Live-verified 2026-09-22 against `catalog.shopify.com/api/ucp/mcp`
        # and two per-shop endpoints: the granular ids answer `search_catalog`
        # with real products at the anonymous tier (no token, no allowlist),
        # the coarse id answers `Tool not found` on the same connection.
        CAPABILITY_IDS = %w[
          dev.ucp.shopping.catalog.search
          dev.ucp.shopping.catalog.lookup
          dev.ucp.shopping.cart
          dev.ucp.shopping.checkout
          dev.ucp.shopping.order
        ].freeze

        # @param out [String] path to write the public profile JSON document
        # @param key_out [String] path to write the new private key's PEM —
        #   caller's responsibility to keep this out of version control
        # @param rotate [Boolean] keep existing signing_keys from `out` (if
        #   it already exists) and add a new one, instead of replacing them
        # @return [Hash] { profile_path:, private_key_path:, kid: } — the
        #   kid of the newly generated key
        def self.generate(out:, key_out:, rotate: false)
          new(out: out, key_out: key_out, rotate: rotate).generate
        end

        def initialize(out:, key_out:, rotate: false)
          @out = out
          @key_out = key_out
          @rotate = rotate
        end

        def generate
          new_key = generate_key
          doc = build_document(carried_forward_keys + [new_key.jwk])

          write_profile(doc)
          write_private_key(new_key.private_pem)

          { profile_path: @out, private_key_path: @key_out, kid: new_key.kid }
        end

        private

        def carried_forward_keys
          return [] unless @rotate && File.exist?(@out)

          JSON.parse(File.read(@out)).fetch("signing_keys", [])
        rescue JSON::ParserError
          []
        end

        def build_document(signing_keys)
          {
            "ucp" => {
              "version" => UCP_VERSION,
              "services" => service_hash,
              "capabilities" => capability_hash,
              "payment_handlers" => {}
            },
            "signing_keys" => signing_keys
          }
        end

        # Was `{}`. A server negotiating capabilities intersects its own
        # service list with the profile's, so an empty `services` declares an
        # agent that speaks no service at all — same class of under-declaration
        # as the coarse capability ids above.
        def service_hash
          { SHOPPING_SERVICE => [{ "version" => UCP_VERSION,
                                   "spec" => "https://ucp.dev/#{UCP_VERSION}/specification/overview",
                                   "transport" => "mcp",
                                   "schema" => "https://ucp.dev/#{UCP_VERSION}/services/shopping/mcp.openrpc.json" }] }
        end

        def capability_hash
          CAPABILITY_IDS.to_h { |id| [id, [{ "version" => UCP_VERSION }]] }
        end

        def write_profile(doc)
          FileUtils.mkdir_p(File.dirname(@out))
          File.write(@out, "#{JSON.pretty_generate(doc)}\n")
        end

        def write_private_key(pem)
          FileUtils.mkdir_p(File.dirname(@key_out))
          File.write(@key_out, pem)
          File.chmod(0o600, @key_out)
        end

        # A JWK's `kid` is derived from the key material itself (RFC 7638
        # thumbprint) rather than assigned, so it can't drift from the key
        # it names — a caller can't accidentally publish a profile where a
        # `kid` points at the wrong entry.
        def generate_key
          pkey = OpenSSL::PKey::EC.generate("prime256v1")
          x_b64, y_b64 = coordinates(pkey)
          kid = thumbprint(x_b64, y_b64)

          jwk = { "kid" => kid, "kty" => "EC", "crv" => "P-256", "x" => x_b64, "y" => y_b64,
                  "use" => "sig", "alg" => "ES256" }

          Key.new(kid: kid, jwk: jwk, private_pem: pkey.to_pem)
        end

        # Raw uncompressed EC point encoding: 0x04 || x (32 bytes) || y (32
        # bytes) for P-256 — see Portage::Ucp::Security::Signature::CURVES,
        # which decodes the same layout in reverse when verifying.
        def coordinates(pkey)
          octets = pkey.public_key.to_bn.to_s(2)
          coord_bytes = 32
          x = octets[1, coord_bytes]
          y = octets[1 + coord_bytes, coord_bytes]
          [url_b64(x), url_b64(y)]
        end

        def thumbprint(x_b64, y_b64)
          canonical = JSON.generate({ "crv" => "P-256", "kty" => "EC", "x" => x_b64, "y" => y_b64 })
          url_b64(Digest::SHA256.digest(canonical))
        end

        def url_b64(bytes)
          Base64.urlsafe_encode64(bytes, padding: false)
        end
      end
    end
  end
end

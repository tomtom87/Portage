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
      # `Portage::Ucp::Manifest::UCP_VERSION` is reused as-is (not
      # redeclared) so the two documents can never drift to different spec
      # versions by accident.
      #
      # Rotation is the future-proofing this exists for: re-running with
      # `rotate: true` keeps every key already published (so a request
      # signed under an older `kid` keeps verifying while callers migrate)
      # and adds one freshly generated key alongside them. Nothing here ever
      # drops a key — retiring one is a deliberate, separate edit once
      # nothing signs with it any more.
      class AgentProfile
        UCP_VERSION = Portage::Ucp::Manifest::UCP_VERSION

        Key = Struct.new(:kid, :jwk, :private_pem, keyword_init: true)

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

        # The four shopping capabilities `Portage::Ucp::Client::Session` always
        # implements, regardless of transport (loopback/stdio/HTTP) — same
        # constants `Portage::Ucp::Manifest` reads off a business's `Adapter`
        # (portage-ucp/lib/portage/ucp/capabilities/*.rb), reused here because
        # this document describes the agent's own fixed capability set rather
        # than one Adapter's opted-in subset.
        AGENT_CAPABILITIES = [
          Portage::Ucp::Capabilities::CATALOG,
          Portage::Ucp::Capabilities::CART,
          Portage::Ucp::Capabilities::CHECKOUT,
          Portage::Ucp::Capabilities::ORDER
        ].freeze

        def build_document(signing_keys)
          {
            "ucp" => {
              "version" => UCP_VERSION,
              "services" => {},
              "capabilities" => capability_hash,
              "payment_handlers" => {}
            },
            "signing_keys" => signing_keys
          }
        end

        # Same shape `Portage::Ucp::Manifest#capability_hash` produces for a
        # business's `/.well-known/ucp` document — confirmed live (see
        # docs/agent-profile.md) that a real UCP server treats an empty
        # `capabilities` here as "this agent can do nothing" and refuses
        # every tool call with `Tool not found`, even ones `tools/list` just
        # returned.
        def capability_hash
          AGENT_CAPABILITIES.to_h { |capability| [capability.name, [{ "version" => capability.version }]] }
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

require "openssl"
require "base64"

module Portage
  module Ucp
    module Security
      # Verifies that an inbound agent request carries a valid RFC 9421 HTTP
      # Message Signature, per UCP's own signature spec
      # (ucp.dev/2026-04-08/specification/signatures/, pinned 2026-09-15 —
      # this is the piece §22 of the design log flagged as unresearched
      # before writing code, now checked against the live spec rather than
      # guessed). This is a distinct concern from three other signing
      # stories already in this gem:
      #   - Manifest (manifest.rb) signs the *outbound* /.well-known/ucp
      #     document with a business-held key.
      #   - Rack::WebhookEndpoint verifies *inbound backend* webhooks by a
      #     shared-secret HMAC.
      #   - Authenticator proves *who* is calling a tools/call, not that a
      #     human consented to the specific purchase.
      # This class verifies that the calling platform's own signature over
      # the HTTP request itself is valid and covers the fields UCP requires
      # — the AP2/UCP authorization story: cryptographic proof bound to this
      # exact method/path/body, not just an API key.
      #
      # Verify-before-parse (matches WebhookEndpoint's posture exactly): the
      # caller passes the raw, unparsed body; nothing here (or in the Rack
      # middleware that wraps it, see Rack::SignatureVerification) touches
      # the body as JSON. An unverified body is untrusted input.
      #
      # Key set shape is reused from Manifest's signing_keys (§9): a flat
      # array of JWK hashes, multiple entries = current+next during
      # rotation. This is deliberately a *different* config value from
      # Manifest's own signing_keys (that's the business's own key,
      # advertised for others to verify the business's manifest with; this
      # is the calling platform's key, trusted by the business to verify
      # inbound requests with) — same shape, not the same data, per §22's
      # instruction not to invent a second differently-shaped key config.
      #
      # `trusted_keys` may be a plain Array<Hash> (JWK) or anything
      # responding to #call(kid) => JWK hash or nil, so a consumer trusting
      # more than one platform can look keys up however it needs to
      # (its own store, a cached fetch of the platform's own manifest) —
      # the gem doesn't assume single-platform trust, without inventing
      # multi-platform discovery logic that isn't pinned anywhere yet.
      class Signature
        # ECDSA only, per the spec: P-256 mandatory, P-384 optional. `coord`
        # is the byte length of each of r/s in the required raw r||s
        # signature encoding (never ASN.1/DER on the wire) and of the JWK's
        # x/y coordinates.
        CURVES = {
          "P-256" => { openssl_name: "prime256v1", oid: "1.2.840.10045.3.1.7", coord: 32, digest: "SHA256" },
          "P-384" => { openssl_name: "secp384r1", oid: "1.3.132.0.34", coord: 48, digest: "SHA384" }
        }.freeze
        EC_PUBLIC_KEY_OID = "1.2.840.10045.2.1".freeze

        SIGNATURE_INPUT_FORMAT = /\A(?<label>[!\w-]+)=\((?<components>[^)]*)\)(?<params>.*)\z/
        SIGNATURE_FORMAT = %r{\A[!\w-]+=:(?<value>[A-Za-z0-9+/=]+):\z}

        # @param method [String] HTTP verb, e.g. "POST"
        # @param authority [String] request Host (and port if non-default)
        # @param path [String] request path, no query string
        # @param query [String, nil] raw query string including leading "?",
        #   or nil/"" when the request has none
        # @param headers [Hash<String, String>] lower-cased header name =>
        #   value, at minimum whatever the sender listed as covered
        #   components (signature-input, signature, content-digest,
        #   content-type, idempotency-key, ucp-agent)
        # @param body [String] raw request body bytes, unparsed
        # @param trusted_keys [Array<Hash>, #call] JWK hash set (or
        #   resolver), see class doc
        # @param required_components [Array<String>] the minimum the signer
        #   must have covered for this to count as proof of anything — a
        #   signature that covers only a harmless header is not a signature
        #   over the request that matters. Defaults to the request-line plus
        #   idempotency-key, since that's what makes replaying a signed
        #   request against a different mutation impossible; content-digest
        #   is required additionally whenever `body` is non-empty.
        # @param max_age [Integer, nil] seconds a signature's `created` may
        #   lag behind now before it's treated as stale (bounds replay of an
        #   otherwise-valid captured request — RFC 9421 leaves freshness
        #   enforcement to the verifier). nil disables the check.
        # @return [Hash] `{ verified: true, keyid: }` — never a falsy result,
        #   raises a Security::SignatureError subclass on any failure instead
        #   so callers can't accidentally ignore one (same convention as
        #   PolicyGuard.check!'s `{ allowed: true }`).
        def self.verify!(method:, authority:, path:, headers:, body:, trusted_keys:, query: nil,
                         required_components: %w[@method @authority @path idempotency-key], max_age: 300)
          new(method: method, authority: authority, path: path, query: query, headers: headers, body: body,
              trusted_keys: trusted_keys, required_components: required_components,
              max_age: max_age).verify!
        end

        def initialize(method:, authority:, path:, headers:, body:, trusted_keys:, required_components:, max_age:,
                       query: nil)
          @method = method
          @authority = authority
          @path = path
          @query = query
          @headers = headers.transform_keys { |k| k.to_s.downcase }
          @body = body || ""
          @trusted_keys = trusted_keys
          @required_components = required_components
          @max_age = max_age
        end

        def verify!
          signature_input = header!("signature-input")
          signature = header!("signature")

          label, components, params = parse_signature_input(signature_input)
          ensure_required_coverage!(components)
          ensure_digest_covered_if_body!(components)
          ensure_fresh!(params)

          key = resolve_key(params[:keyid])
          raise UnknownKeyError, "no trusted key for keyid #{params[:keyid].inspect}" unless key

          verify_content_digest!(components) unless @body.empty?

          base = signature_base(components, label, signature_input)
          raw_signature = decode_signature(signature)
          verify_ecdsa!(key, base, raw_signature)

          { verified: true, keyid: params[:keyid] }
        end

        private

        def header!(name)
          @headers[name] || raise(MissingSignatureError, "missing #{name} header")
        end

        def parse_signature_input(raw)
          match = SIGNATURE_INPUT_FORMAT.match(raw)
          raise MalformedSignatureError, "unparsable Signature-Input" unless match

          components = match[:components].scan(/"([^"]+)"/).flatten
          params = match[:params].scan(/;([\w-]+)=(?:"([^"]*)"|([^;]+))/).each_with_object({}) do |(k, quoted, bare), h|
            h[k.to_sym] = quoted || bare
          end
          [match[:label], components, params]
        rescue ArgumentError
          raise MalformedSignatureError, "unparsable Signature-Input"
        end

        def ensure_required_coverage!(components)
          missing = @required_components - components
          return if missing.empty?

          raise MalformedSignatureError, "signature doesn't cover required component(s): #{missing.join(', ')}"
        end

        def ensure_digest_covered_if_body!(components)
          return if @body.empty? || components.include?("content-digest")

          raise MalformedSignatureError, "request has a body but signature doesn't cover content-digest"
        end

        def ensure_fresh!(params)
          return unless @max_age

          created = Integer(params[:created], exception: false)
          raise StaleSignatureError, "Signature-Input missing a usable created timestamp" unless created

          age = Time.now.to_i - created
          raise StaleSignatureError, "signature is #{age}s old, older than max_age #{@max_age}s" if age > @max_age
        end

        def resolve_key(kid)
          return nil unless kid

          if @trusted_keys.respond_to?(:call)
            @trusted_keys.call(kid)
          else
            Array(@trusted_keys).find { |k| (k["kid"] || k[:kid]) == kid }
          end
        end

        def verify_content_digest!(components)
          return unless components.include?("content-digest")

          header_value = header!("content-digest")
          match = %r{sha-(?<bits>256|512)=:(?<value>[A-Za-z0-9+/=]+):}.match(header_value)
          raise DigestMismatchError, "unsupported or unparsable content-digest" unless match

          digest_name = "SHA#{match[:bits]}"
          expected = Base64.strict_decode64(match[:value])
          actual = OpenSSL::Digest.digest(digest_name, @body)
          return if digests_match?(expected, actual)

          raise DigestMismatchError, "content-digest doesn't match request body"
        end

        def signature_base(components, label, raw_signature_input)
          lines = components.map { |name| %("#{name}": #{component_value(name)}) }
          params_value = raw_signature_input.sub(/\A#{Regexp.escape(label)}=/, "")
          lines << %("@signature-params": #{params_value})
          lines.join("\n")
        end

        def component_value(name)
          case name
          when "@method" then @method.to_s.upcase
          when "@authority" then @authority.to_s
          when "@path" then @path.to_s
          when "@query" then @query.to_s
          else
            header!(name)
          end
        end

        def decode_signature(header)
          match = SIGNATURE_FORMAT.match(header)
          raise MalformedSignatureError, "unparsable Signature header" unless match

          Base64.strict_decode64(match[:value])
        rescue ArgumentError
          raise MalformedSignatureError, "unparsable Signature header"
        end

        def verify_ecdsa!(jwk, base, raw_signature)
          crv = jwk["crv"] || jwk[:crv]
          curve = CURVES.fetch(crv) { raise MalformedSignatureError, "unsupported curve #{crv.inspect}" }
          unless raw_signature.bytesize == curve[:coord] * 2
            raise InvalidSignatureError,
                  "signature is the wrong length for #{crv}"
          end

          key = ec_public_key(jwk, curve)
          der = raw_to_der(raw_signature, curve[:coord])
          verified = key.verify(curve[:digest], der, base)
          raise InvalidSignatureError, "signature does not verify" unless verified
        rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::EC::Point::Error, OpenSSL::ASN1::ASN1Error => e
          raise InvalidSignatureError, "signature verification failed: #{e.message}"
        end

        # Builds the public key from raw DER rather than
        # OpenSSL::PKey::EC#public_key= — that setter no longer works since
        # EC keys became immutable in the openssl gem's OpenSSL 3.0 support.
        def ec_public_key(jwk, curve)
          x = decode_base64url(jwk["x"] || jwk[:x])
          y = decode_base64url(jwk["y"] || jwk[:y])
          raise MalformedSignatureError, "JWK missing x/y" if x.nil? || y.nil?

          octet_string = "\x04".b + x + y
          der = OpenSSL::ASN1::Sequence.new([
                                              OpenSSL::ASN1::Sequence.new([
                                                                            OpenSSL::ASN1::ObjectId.new(EC_PUBLIC_KEY_OID),
                                                                            OpenSSL::ASN1::ObjectId.new(curve[:oid])
                                                                          ]),
                                              OpenSSL::ASN1::BitString.new(octet_string)
                                            ]).to_der
          OpenSSL::PKey::EC.new(der)
        end

        def raw_to_der(raw_signature, coord)
          r = OpenSSL::BN.new(raw_signature.byteslice(0, coord), 2)
          s = OpenSSL::BN.new(raw_signature.byteslice(coord, coord), 2)
          OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
        end

        def decode_base64url(value)
          return nil unless value

          padded = value + ("=" * ((4 - (value.length % 4)) % 4))
          Base64.urlsafe_decode64(padded)
        end

        def digests_match?(expected, actual)
          return false unless expected.bytesize == actual.bytesize

          expected.bytes.zip(actual.bytes).reduce(0) { |acc, (byte_a, byte_b)| acc | (byte_a ^ byte_b) }.zero?
        end
      end
    end
  end
end

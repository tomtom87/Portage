require "openssl"
require "base64"

module Portage
  module Ucp
    module Ap2
      # Cryptographic verification of a PaymentMandate's `signature` — the
      # piece MandateGuard's own comment (and PaymentMandate's, before this
      # file existed) flagged as deliberately missing: "no key infrastructure
      # or trust anchor exists in this repo to verify a signature against."
      # A caller that now has a trust anchor (a real PSP adapter, or a
      # platform-provided key resolver) passes it as `trusted_keys:` to get
      # actual proof instead of shape-only validation.
      #
      # Same ECDSA/JWK wire conventions as Security::Signature (P-256
      # mandatory/P-384 optional, raw r||s signature bytes, JWK x/y
      # coordinates) since that curve support is already proven against this
      # gem's RFC 9421 verifier — but deliberately a separate class, not a
      # shared one: a mandate isn't an HTTP request (no method/path/headers
      # to canonicalize, just PaymentMandate#signing_payload), and
      # Security::Signature's own class doc already frames every signing
      # story in this gem as deliberately distinct rather than unified under
      # one abstraction.
      #
      # Trust anchor: `trusted_keys` here is the mandate *issuer's* key set
      # (the shopper's agent, or the agent platform vouching for it) — a
      # different trust root than Security::Signature's `trusted_keys` (the
      # calling platform's own request-signing key), even though both reuse
      # the same flat-JWK-array-or-#call(kid)-resolver shape (§9's
      # convention, reused again here rather than inventing a second
      # differently-shaped key config for the same job).
      module MandateSignature
        CURVES = {
          "P-256" => { oid: "1.2.840.10045.3.1.7", coord: 32, digest: "SHA256" },
          "P-384" => { oid: "1.3.132.0.34", coord: 48, digest: "SHA384" }
        }.freeze
        EC_PUBLIC_KEY_OID = "1.2.840.10045.2.1".freeze

        # @param mandate [PaymentMandate]
        # @param trusted_keys [Array<Hash>, #call] JWK hash set (or
        #   resolver #call(kid) => JWK hash or nil), keyed by `kid` — see
        #   module doc.
        # @return [true] never a falsy result; raises
        #   Portage::Ucp::InvalidMandateError on any failure so a caller
        #   can't accidentally treat "didn't check" as "checked and passed"
        #   (same convention as Security::Signature.verify!).
        def self.verify!(mandate, trusted_keys:)
          jwk = trust_key!(mandate, trusted_keys)
          curve = curve_for!(jwk)
          raw_signature = sized_signature!(mandate, curve)

          key = ec_public_key(jwk, curve)
          der = raw_to_der(raw_signature, curve[:coord])
          verified = key.verify(curve[:digest], der, mandate.signing_payload)
          raise Portage::Ucp::InvalidMandateError, "mandate signature does not verify" unless verified

          true
        rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::EC::Point::Error, OpenSSL::ASN1::ASN1Error => e
          raise Portage::Ucp::InvalidMandateError, "mandate signature verification failed: #{e.message}"
        end

        def self.trust_key!(mandate, trusted_keys)
          kid = mandate.kid
          raise Portage::Ucp::InvalidMandateError, "mandate has no kid to resolve a trust key by" unless kid

          jwk = resolve_key(trusted_keys, kid)
          raise Portage::Ucp::InvalidMandateError, "no trusted key for mandate kid #{kid.inspect}" unless jwk

          jwk
        end
        private_class_method :trust_key!

        def self.curve_for!(jwk)
          crv = jwk["crv"] || jwk[:crv]
          CURVES.fetch(crv) { raise Portage::Ucp::InvalidMandateError, "unsupported curve #{crv.inspect}" }
        end
        private_class_method :curve_for!

        def self.sized_signature!(mandate, curve)
          raw_signature = decode_signature(mandate.signature)
          unless raw_signature.bytesize == curve[:coord] * 2
            raise Portage::Ucp::InvalidMandateError, "mandate signature is the wrong length for #{curve}"
          end

          raw_signature
        end
        private_class_method :sized_signature!

        def self.resolve_key(trusted_keys, kid)
          if trusted_keys.respond_to?(:call)
            trusted_keys.call(kid)
          else
            Array(trusted_keys).find { |k| (k["kid"] || k[:kid]) == kid }
          end
        end
        private_class_method :resolve_key

        def self.decode_signature(value)
          Base64.strict_decode64(value.to_s)
        rescue ArgumentError
          raise Portage::Ucp::InvalidMandateError, "mandate signature isn't valid base64"
        end
        private_class_method :decode_signature

        # Same DER-from-raw-JWK-coordinates construction as
        # Security::Signature#ec_public_key, for the same reason: the
        # OpenSSL::PKey::EC#public_key= setter no longer works since EC keys
        # became immutable in the openssl gem's OpenSSL 3.0 support.
        def self.ec_public_key(jwk, curve)
          x = decode_base64url(jwk["x"] || jwk[:x])
          y = decode_base64url(jwk["y"] || jwk[:y])
          raise Portage::Ucp::InvalidMandateError, "JWK missing x/y" if x.nil? || y.nil?

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
        private_class_method :ec_public_key

        def self.raw_to_der(raw_signature, coord)
          r = OpenSSL::BN.new(raw_signature.byteslice(0, coord), 2)
          s = OpenSSL::BN.new(raw_signature.byteslice(coord, coord), 2)
          OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
        end
        private_class_method :raw_to_der

        def self.decode_base64url(value)
          return nil unless value

          padded = value + ("=" * ((4 - (value.length % 4)) % 4))
          Base64.urlsafe_decode64(padded)
        rescue ArgumentError
          raise Portage::Ucp::InvalidMandateError, "JWK coordinate isn't valid base64url"
        end
        private_class_method :decode_base64url
      end
    end
  end
end

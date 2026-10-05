require "openssl"
require "base64"
require_relative "../security/ec_jwk"

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
      # coordinates), and the same Security::EcJwk helpers for them, since
      # that curve support is already proven against this gem's RFC 9421
      # verifier. The verifier itself stays separate: a mandate isn't an
      # HTTP request (no method/path/headers to canonicalize, just
      # PaymentMandate#signing_payload), and Security::Signature's own class
      # doc frames every signing story in this gem as deliberately distinct.
      #
      # Trust anchor: `trusted_keys` here is the mandate *issuer's* key set
      # (the shopper's agent, or the agent platform vouching for it) — a
      # different trust root than Security::Signature's `trusted_keys` (the
      # calling platform's own request-signing key), even though both reuse
      # the same flat-JWK-array-or-#call(kid)-resolver shape (§9's
      # convention, reused again here rather than inventing a second
      # differently-shaped key config for the same job).
      module MandateSignature
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

          key = Security::EcJwk.public_key(jwk, curve, error: Portage::Ucp::InvalidMandateError)
          der = Security::EcJwk.raw_to_der(raw_signature, curve[:coord])
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
          kty = jwk["kty"] || jwk[:kty]
          raise Portage::Ucp::InvalidMandateError, "unsupported key type #{kty.inspect}" unless kty == "EC"

          crv = jwk["crv"] || jwk[:crv]
          Security::EcJwk::CURVES.fetch(crv) do
            raise Portage::Ucp::InvalidMandateError, "unsupported curve #{crv.inspect}"
          end
        end
        private_class_method :curve_for!

        def self.sized_signature!(mandate, curve)
          raw_signature = decode_signature(mandate.signature)
          unless raw_signature.bytesize == curve[:coord] * 2
            raise Portage::Ucp::InvalidMandateError, "mandate signature is the wrong length for #{curve[:digest]}"
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
      end
    end
  end
end

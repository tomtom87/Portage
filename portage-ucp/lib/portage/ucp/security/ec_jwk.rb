require "openssl"
require "base64"

module Portage
  module Ucp
    module Security
      # The ECDSA/JWK wire conventions Security::Signature (RFC 9421
      # requests) and Ap2::MandateSignature (payment mandates) share: P-256
      # mandatory, P-384 optional, a public key from the JWK's raw x/y
      # coordinates, and raw r||s signature bytes (never ASN.1/DER on the
      # wire). `coord` is the byte length of each of r/s and of x/y.
      #
      # Each caller passes the error class it raises for a malformed JWK, so
      # a bad key stays a SignatureError for one and an InvalidMandateError
      # for the other.
      module EcJwk
        CURVES = {
          "P-256" => { oid: "1.2.840.10045.3.1.7", coord: 32, digest: "SHA256" },
          "P-384" => { oid: "1.3.132.0.34", coord: 48, digest: "SHA384" }
        }.freeze
        EC_PUBLIC_KEY_OID = "1.2.840.10045.2.1".freeze

        module_function

        # Builds the public key from raw DER rather than
        # OpenSSL::PKey::EC#public_key= — that setter no longer works since
        # EC keys became immutable in the openssl gem's OpenSSL 3.0 support.
        def public_key(jwk, curve, error:)
          x = decode_base64url(jwk["x"] || jwk[:x], error: error)
          y = decode_base64url(jwk["y"] || jwk[:y], error: error)
          raise error, "JWK missing x/y" if x.nil? || y.nil?

          octet_string = "\x04".b + x + y
          algorithm = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::ObjectId.new(EC_PUBLIC_KEY_OID),
                                                   OpenSSL::ASN1::ObjectId.new(curve[:oid])])
          OpenSSL::PKey::EC.new(OpenSSL::ASN1::Sequence.new([algorithm, OpenSSL::ASN1::BitString.new(octet_string)]).to_der)
        end

        def raw_to_der(raw_signature, coord)
          r = OpenSSL::BN.new(raw_signature.byteslice(0, coord), 2)
          s = OpenSSL::BN.new(raw_signature.byteslice(coord, coord), 2)
          OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
        end

        def decode_base64url(value, error:)
          return nil unless value

          padded = value + ("=" * ((4 - (value.length % 4)) % 4))
          Base64.urlsafe_decode64(padded)
        rescue ArgumentError
          raise error, "JWK coordinate isn't valid base64url"
        end
      end
    end
  end
end

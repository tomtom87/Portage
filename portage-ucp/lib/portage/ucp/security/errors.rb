module Portage
  module Ucp
    module Security
      # Base for every failure Signature.verify! can raise. Callers that only
      # care "was this request's consent proof valid or not" can rescue this
      # one class; the subclasses exist so a Rack middleware or logger can
      # report *why* without parsing message text.
      class SignatureError < Portage::Ucp::Error; end

      # No Signature-Input/Signature header pair present at all.
      class MissingSignatureError < SignatureError; end

      # Signature-Input or Signature present but doesn't parse as the
      # RFC 9421 structured-field shape this gem understands.
      class MalformedSignatureError < SignatureError; end

      # Signature-Input's `keyid` doesn't match any entry in the configured
      # trusted key set (§9a's current+next rotation set, reused — see
      # Signature module doc).
      class UnknownKeyError < SignatureError; end

      # A signed `content-digest` component was present but the request body's
      # actual digest doesn't match it — the body was altered after signing,
      # or the digest was forged independently of the signature itself.
      class DigestMismatchError < SignatureError; end

      # The cryptographic signature itself doesn't verify against the
      # reconstructed signature base — tampering, wrong key, or wrong alg.
      class InvalidSignatureError < SignatureError; end

      # Signature-Input's `created` is older than the configured max age.
      # Bounds replay of an otherwise-valid captured request; RFC 9421 leaves
      # freshness enforcement to the verifier, not the wire format.
      class StaleSignatureError < SignatureError; end
    end
  end
end

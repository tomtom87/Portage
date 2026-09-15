require "openssl"
require "base64"

# Builds real signed requests the same way an RFC 9421-compliant platform
# would, independent of Security::Signature/Rack::SignatureVerification's own
# internals, so those specs check against the wire format rather than
# against themselves. Shared between spec/security/signature_spec.rb and
# spec/rack/signature_verification_spec.rb.
module SigningHelper
  module_function

  def keypair(curve_name = "prime256v1")
    OpenSSL::PKey::EC.generate(curve_name)
  end

  def jwk(ec_key, kid:, crv: "P-256")
    coord = crv == "P-256" ? 32 : 48
    point = ec_key.public_key.to_bn.to_s(2)
    x = point.byteslice(1, coord)
    y = point.byteslice(1 + coord, coord)
    { "kid" => kid, "kty" => "EC", "crv" => crv,
      "x" => Base64.urlsafe_encode64(x, padding: false), "y" => Base64.urlsafe_encode64(y, padding: false) }
  end

  def content_digest(body)
    "sha-256=:#{Base64.strict_encode64(OpenSSL::Digest.digest('SHA256', body))}:"
  end

  # @return [Hash] the full header set a caller would send, including
  #   Signature-Input/Signature, ready to hand to Signature.verify! or post
  #   as Rack env HTTP_* entries.
  def sign(ec_key:, kid:, method:, authority:, path:, headers:, body:, query: nil, digest_name: "SHA256",
           coord: 32, components: %w[@method @authority @path idempotency-key content-digest], created: Time.now.to_i)
    all_headers = headers.dup
    all_headers["content-digest"] = content_digest(body) if components.include?("content-digest")

    params = %(;created=#{created};keyid="#{kid}")
    base = build_base(components, method, authority, path, query, all_headers, params)

    raw = der_to_raw(ec_key.sign(digest_name, base), coord)

    all_headers["signature-input"] = %(sig1=(#{quoted_list(components)})#{params})
    all_headers["signature"] = "sig1=:#{Base64.strict_encode64(raw)}:"
    all_headers
  end

  def build_base(components, method, authority, path, query, headers, params)
    lines = components.map do |name|
      value = case name
              when "@method" then method
              when "@authority" then authority
              when "@path" then path
              when "@query" then query.to_s
              else headers.fetch(name)
              end
      %("#{name}": #{value})
    end
    lines << %("@signature-params": (#{quoted_list(components)})#{params})
    lines.join("\n")
  end

  def der_to_raw(der, coord)
    seq = OpenSSL::ASN1.decode(der)
    r = seq.value[0].value.to_s(2)
    s = seq.value[1].value.to_s(2)
    r.rjust(coord, "\x00") + s.rjust(coord, "\x00")
  end

  def quoted_list(components)
    components.map { |c| "\"#{c}\"" }.join(" ")
  end
end

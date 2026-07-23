module UcpMcp
  # PCI boundary guard (§9). complete_checkout's payment_token must be a
  # single-use, tokenized credential from a UCP payment handler / AP2
  # exchange — never a raw PAN. This can't prove a string *is* an opaque
  # token, but it can catch the clearest misintegration: something that
  # looks exactly like a card number (digits only, 12-19 characters,
  # Luhn-valid) gets rejected before it ever reaches an Adapter, so a
  # misintegrated agent can't push card numbers through the gem.
  module PaymentTokenGuard
    PAN_LENGTHS = (12..19)

    def self.validate!(token)
      return unless looks_like_pan?(token)

      raise UcpMcp::RawPanRejectedError,
            "payment_token looks like a raw PAN (digits only, Luhn-valid) — " \
            "complete_checkout requires a tokenized credential, never card data"
    end

    def self.looks_like_pan?(token)
      digits = token.to_s
      return false unless digits.match?(/\A\d+\z/) && PAN_LENGTHS.cover?(digits.length)

      luhn_valid?(digits)
    end

    def self.luhn_valid?(digits)
      sum = digits.reverse.chars.map(&:to_i).each_with_index.sum do |digit, index|
        next digit if index.even?

        doubled = digit * 2
        doubled > 9 ? doubled - 9 : doubled
      end

      (sum % 10).zero?
    end
    private_class_method :luhn_valid?
  end
end

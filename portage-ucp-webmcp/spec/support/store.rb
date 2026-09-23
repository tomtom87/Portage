# A seeded Portage::Ucp::ReferenceAdapter — the conformance kit's own
# fixture, so the WebMCP specs exercise the real Adapter contract rather than
# a WebMCP-specific stub — plus an Authenticator that stands in for a host
# app's cookie/CSRF check.
module Store
  module_function

  CSRF_TOKEN = "csrf-ok".freeze

  def adapter
    Portage::Ucp::ReferenceAdapter.new.tap do |adapter|
      adapter.seed_product(product(id: "mug", title: "Enamel Mug", price_minor: 1800))
      adapter.seed_product(product(id: "tee", title: "Pocket Tee", price_minor: 3200))
    end
  end

  def product(id:, title:, price_minor:)
    price = Portage::Ucp::Price.new(amount: price_minor, currency: "USD")
    variant = Portage::Ucp::Variant.new(
      id: "#{id}_default", title: title, description: Portage::Ucp::Description.new(plain: title),
      price: price, availability: { "available" => true }
    )
    Portage::Ucp::Product.new(
      id: id, title: title, description: Portage::Ucp::Description.new(plain: title),
      price_range: Portage::Ucp::PriceRange.new(min: price, max: price), variants: [variant]
    )
  end

  # Accepts a request carrying the host app's CSRF header — what a real
  # Authenticator behind Rack::CallEndpoint would check alongside the
  # session cookie on `server_context[:request]`.
  def authenticator
    lambda do |server_context|
      request = server_context[:request]
      return :shopper if request && request.get_header("HTTP_X_CSRF_TOKEN") == CSRF_TOKEN

      raise Portage::Ucp::AuthenticationError, "missing or invalid CSRF token"
    end
  end

  def catalog(**)
    Portage::Ucp::WebMcp::ToolCatalog.new(adapter: adapter, authenticator: authenticator, **)
  end

  # For comparing transports side by side, where there is no Rack request to
  # check a CSRF header on.
  def permissive_authenticator
    ->(_server_context) { :shopper }
  end
end

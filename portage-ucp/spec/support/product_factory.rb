# Builds a minimal spec-conformant Portage::Ucp::Product (single variant,
# price_range collapsed to that one variant's price) — the shape every
# core-gem spec needs just to seed a catalog entry, without each spec
# hand-assembling Price/Description/Variant/Product itself.
module ProductFactory
  module_function

  def build(id:, title:, price_minor:, currency: "USD", description: "desc", available: true, url: nil)
    price = Portage::Ucp::Price.new(amount: price_minor, currency: currency)
    variant = Portage::Ucp::Variant.new(
      id: "#{id}_default", title: title, description: Portage::Ucp::Description.new(plain: description),
      price: price, availability: { "available" => available }
    )
    Portage::Ucp::Product.new(
      id: id, title: title, description: Portage::Ucp::Description.new(plain: description),
      price_range: Portage::Ucp::PriceRange.new(min: price, max: price), variants: [variant], url: url
    )
  end
end

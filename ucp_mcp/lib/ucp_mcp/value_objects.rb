module UcpMcp
  Money = Data.define(:amount_minor, :currency)
  Product = Data.define(:id, :title, :description, :price, :available, :variants, :url)
  LineItem = Data.define(:id, :product_id, :quantity, :unit_price, :total)
  Cart = Data.define(:id, :line_items, :subtotal, :currency)
  Checkout = Data.define(:id, :status, :line_items, :subtotal, :tax, :total,
                         :currency, :locale, :available_payment_handlers)
  Order = Data.define(:id, :status, :line_items, :total, :currency, :placed_at)
  Identity = Data.define(:subject, :email, :linked_at)
end

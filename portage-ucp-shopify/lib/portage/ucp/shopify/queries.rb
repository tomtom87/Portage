module Portage
  module Ucp
    module Shopify
      # Raw GraphQL documents, kept separate from Adapter so the request shape
      # and the response mapping (Mapper) can each be read and tested on their
      # own.
      module Queries
        PRODUCT_FIELDS = <<~GRAPHQL.freeze
          id
          title
          description
          onlineStoreUrl
          availableForSale
          priceRange { minVariantPrice { amount currencyCode } }
          variants(first: 25) {
            nodes { id title availableForSale price { amount currencyCode } }
          }
        GRAPHQL

        SEARCH_CATALOG = <<~GRAPHQL.freeze
          query SearchCatalog($query: String!, $first: Int!) {
            products(query: $query, first: $first) { nodes { #{PRODUCT_FIELDS} } }
          }
        GRAPHQL

        GET_PRODUCT = <<~GRAPHQL.freeze
          query GetProduct($id: ID!) {
            product(id: $id) { #{PRODUCT_FIELDS} }
          }
        GRAPHQL

        CART_FIELDS = <<~GRAPHQL.freeze
          id
          checkoutUrl
          cost { subtotalAmount { amount currencyCode } totalTaxAmount { amount currencyCode }
                 totalAmount { amount currencyCode } }
          lines(first: 100) {
            nodes {
              id quantity
              cost { totalAmount { amount currencyCode } }
              merchandise { ... on ProductVariant { id product { id title } price { amount currencyCode } } }
            }
          }
        GRAPHQL

        GET_CART = <<~GRAPHQL.freeze
          query GetCart($id: ID!) {
            cart(id: $id) { #{CART_FIELDS} }
          }
        GRAPHQL

        CART_CREATE = <<~GRAPHQL.freeze
          mutation CartCreate($input: CartInput!) {
            cartCreate(input: $input) { cart { #{CART_FIELDS} } userErrors { field message } }
          }
        GRAPHQL

        CART_LINES_ADD = <<~GRAPHQL.freeze
          mutation CartLinesAdd($cartId: ID!, $lines: [CartLineInput!]!) {
            cartLinesAdd(cartId: $cartId, lines: $lines) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        CART_LINES_REMOVE = <<~GRAPHQL.freeze
          mutation CartLinesRemove($cartId: ID!, $lineIds: [ID!]!) {
            cartLinesRemove(cartId: $cartId, lineIds: $lineIds) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        CART_BUYER_IDENTITY_UPDATE = <<~GRAPHQL.freeze
          mutation CartBuyerIdentityUpdate($cartId: ID!, $buyerIdentity: CartBuyerIdentityInput!) {
            cartBuyerIdentityUpdate(cartId: $cartId, buyerIdentity: $buyerIdentity) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        CART_PAYMENT_UPDATE = <<~GRAPHQL.freeze
          mutation CartPaymentUpdate($cartId: ID!, $payment: CartPaymentInput!) {
            cartPaymentUpdate(cartId: $cartId, payment: $payment) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        CART_SUBMIT_FOR_COMPLETION = <<~GRAPHQL.freeze
          mutation CartSubmitForCompletion($cartId: ID!, $attemptToken: String!) {
            cartSubmitForCompletion(cartId: $cartId, attemptId: $attemptToken) {
              result {
                ... on SubmitSuccess { attemptId }
                ... on SubmitAlreadyAccepted { attemptId }
                ... on SubmitFailed { checkoutUrl errors { message } }
                ... on SubmitThrottled { pollAfter }
              }
              userErrors { field message }
            }
          }
        GRAPHQL

        GET_ORDER = <<~GRAPHQL.freeze
          query GetOrder($id: ID!) {
            order(id: $id) {
              id
              statusPageUrl
              currentTotalPriceSet { shopMoney { amount currencyCode } }
              currentSubtotalPriceSet { shopMoney { amount currencyCode } }
              lineItems(first: 100) {
                nodes {
                  id quantity currentQuantity unfulfilledQuantity
                  discountedTotalSet { shopMoney { amount currencyCode } }
                  variant { id title price { amount currencyCode } }
                }
              }
              fulfillmentOrders(first: 25) {
                nodes {
                  id
                  fulfillAt
                  deliveryMethod { methodType }
                  destination { address1 address2 city province zip countryCode firstName lastName phone }
                  lineItems(first: 100) {
                    nodes { totalQuantity lineItem { id } }
                  }
                }
              }
              fulfillments(first: 25) {
                id
                displayStatus
                createdAt
                trackingInfo(first: 5) { company number url }
                fulfillmentLineItems(first: 100) {
                  nodes { quantity lineItem { id } }
                }
              }
            }
          }
        GRAPHQL

        # Storefront's cartSubmitForCompletion never returns the resulting
        # order's id (its SubmitSuccess payload only carries attemptId) — the
        # Admin API's `orders(query:)` search supports a documented
        # `cart_token:` filter ("the token references the cart that's
        # associated with an order"), which is the only way to reconcile a
        # completed cart back to the Order it produced.
        ORDER_BY_CART_TOKEN = <<~GRAPHQL.freeze
          query OrderByCartToken($query: String!) {
            orders(first: 1, query: $query) { nodes { id statusPageUrl } }
          }
        GRAPHQL
      end
    end
  end
end

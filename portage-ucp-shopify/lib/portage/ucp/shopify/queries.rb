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
              merchandise {
                ... on ProductVariant {
                  id
                  product { id title }
                  price { amount currencyCode }
                  availableForSale
                }
              }
            }
          }
          deliveryGroups {
            id
            cartLines(first: 100) { nodes { id } }
            deliveryOptions { handle title description deliveryMethodType estimatedCost { amount currencyCode } }
            selectedDeliveryOption { handle }
            deliveryAddress { address1 address2 city provinceCode zip firstName lastName phone
                              countryCode: countryCodeV2 }
          }
          discountCodes { code applicable }
          discountAllocations {
            discountedAmount { amount currencyCode }
            ... on CartAutomaticDiscountAllocation { title }
            ... on CartCodeDiscountAllocation { code }
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

        # `CartSelectableAddressInput`'s nested shape (Storefront API's
        # current replacement for the deprecated
        # CartBuyerIdentityInput#deliveryAddressPreferences path) is the
        # adapter's mapping of dev.ucp.shopping.fulfillment's
        # ShippingDestination onto it. Confirmed live against a real dev
        # store 2026-08-21 — see design-log.md #18. CART_PAYMENT_UPDATE's
        # paymentMethod sub-shape below is still unconfirmed (roadmap step 5).
        CART_DELIVERY_ADDRESSES_ADD = <<~GRAPHQL.freeze
          mutation CartDeliveryAddressesAdd($cartId: ID!, $addresses: [CartSelectableAddressInput!]!) {
            cartDeliveryAddressesAdd(cartId: $cartId, addresses: $addresses) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        CART_SELECTED_DELIVERY_OPTIONS_UPDATE = <<~GRAPHQL.freeze
          mutation CartSelectedDeliveryOptionsUpdate($cartId: ID!,
                                                      $selectedDeliveryOptions: [CartSelectedDeliveryOptionInput!]!) {
            cartSelectedDeliveryOptionsUpdate(cartId: $cartId, selectedDeliveryOptions: $selectedDeliveryOptions) {
              cart { #{CART_FIELDS} }
              userErrors { field message }
            }
          }
        GRAPHQL

        # Full-replacement, matching dev.ucp.shopping.discount's `codes`
        # semantics — an empty array clears whatever codes were on the cart.
        CART_DISCOUNT_CODES_UPDATE = <<~GRAPHQL.freeze
          mutation CartDiscountCodesUpdate($cartId: ID!, $discountCodes: [String!]!) {
            cartDiscountCodesUpdate(cartId: $cartId, discountCodes: $discountCodes) {
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
              cancelledAt
              cancelReason
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
              refunds(first: 25) {
                id
                createdAt
                note
                totalRefundedSet { shopMoney { amount currencyCode } }
                refundLineItems(first: 100) {
                  nodes { quantity lineItem { id } }
                }
              }
              returns(first: 25) {
                nodes {
                  id
                  status
                  requestedAt
                  returnLineItems(first: 100) {
                    nodes {
                      quantity
                      returnReasonNote
                      fulfillmentLineItem { lineItem { id } }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL

        # orderCancel is async (returns a job, not the updated Order) — the
        # adapter re-fetches via GET_ORDER afterwards for the current state,
        # same posture as #cancel_checkout not trusting a mutation payload
        # over a fresh read. `reason` is fixed to OTHER: UCP's cancel_order
        # only carries a free-text note (`staffNote`), it doesn't expose
        # Shopify's closed OrderCancelReason enum.
        ORDER_CANCEL = <<~GRAPHQL.freeze
          mutation OrderCancel($orderId: ID!, $staffNote: String) {
            orderCancel(orderId: $orderId, reason: OTHER, refund: false, restock: false, staffNote: $staffNote) {
              job { id done }
              orderCancelUserErrors { field message code }
            }
          }
        GRAPHQL

        # refundCreate requires explicit `transactions:` (which gateway
        # transaction to refund against, and how much) — suggestedRefund is
        # Shopify's documented way to compute that breakdown instead of the
        # adapter guessing at payment-gateway specifics. #refund_order runs
        # this first, then feeds its `transactions` straight into
        # REFUND_CREATE's input.
        SUGGESTED_REFUND = <<~GRAPHQL.freeze
          query SuggestedRefund($orderId: ID!, $refundLineItems: [RefundLineItemInput!]!) {
            order(id: $orderId) {
              suggestedRefund(refundLineItems: $refundLineItems) {
                transactions {
                  orderId
                  gateway
                  kind
                  amountSet { shopMoney { amount currencyCode } }
                  parentTransaction { id }
                }
              }
            }
          }
        GRAPHQL

        REFUND_CREATE = <<~GRAPHQL.freeze
          mutation RefundCreate($input: RefundInput!) {
            refundCreate(input: $input) {
              refund {
                id
                createdAt
                note
                totalRefundedSet { shopMoney { amount currencyCode } }
                refundLineItems(first: 100) { nodes { quantity lineItem { id } } }
              }
              userErrors { field message }
            }
          }
        GRAPHQL

        # returnCreate's returnLineItems key off `fulfillmentLineItemId`, not
        # the plain order-line-item id REFUND_CREATE's refundLineItems use —
        # a real return targets what was actually fulfilled. `request_return`
        # callers pass fulfillment line item ids in `line_items:` for this
        # action specifically; needs confirming against a live store, same
        # caveat as #complete_checkout's payment sub-shape.
        RETURN_CREATE = <<~GRAPHQL.freeze
          mutation ReturnCreate($returnInput: ReturnInput!) {
            returnCreate(returnInput: $returnInput) {
              return { id status }
              userErrors { field message }
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

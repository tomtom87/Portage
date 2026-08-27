require "spec_helper"

# Design-log §17 handoff: runs the core gem's conformance kit against a real
# Shopify dev store instead of webmock stubs, so the three sequential
# checkout mutations (cartCreate -> cartPaymentUpdate -> cartSubmitForCompletion)
# each get a genuine response instead of one fixed stub body answering all
# three. spec_helper.rb calls WebMock.disable_net_connect! with no args for
# the rest of the suite; rather than widen that globally, the hole is opened
# only around this file's own examples (see the `around` block below).
#
# Needs SHOPIFY_SHOP_DOMAIN / SHOPIFY_ADMIN_ACCESS_TOKEN /
# SHOPIFY_STOREFRONT_ACCESS_TOKEN in the environment — sourced here from the
# repo-root .env if present and not already set. Every example skips itself
# when SHOPIFY_SHOP_DOMAIN is absent, so `rspec` still passes in CI with no
# live store configured. The admin token is not static (~24h expiry via
# AccessTokenFetcher, see the Rakefile's shopify_access_token task) — if this
# starts failing with an auth error, regenerate it before assuming the
# adapter regressed.
env_path = File.expand_path("../../../../../.env", __dir__)
if File.exist?(env_path)
  File.readlines(env_path).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    ENV[key] ||= value
  end
end

shop_domain = ENV["SHOPIFY_SHOP_DOMAIN"]

RSpec.describe Portage::Ucp::Shopify::Adapter, :live_store do
  unless shop_domain
    before do
      skip "SHOPIFY_SHOP_DOMAIN not set — see docs/design-log.md §17 for how to set up a live test store"
    end
  end

  around do |example|
    next example.run unless shop_domain

    WebMock.disable_net_connect!(allow: shop_domain)
    begin
      example.run
    ensure
      WebMock.disable_net_connect!
    end
  end

  # These lets must live inside the it_behaves_like block below, not at
  # this describe's own level: the kit defines its own
  # `let(:existing_variant_id) { existing_product_id }` directly in the
  # nested group `it_behaves_like` creates, and a `let` from *this* outer
  # group doesn't shadow one the shared example re-defines in that inner
  # group — only a `let` passed into the block does (same pattern the
  # kit's own doc comment shows).
  it_behaves_like "a portage adapter" do
    let(:client) do
      Portage::Ucp::Shopify::Client.new(
        shop_domain: shop_domain,
        admin_access_token: ENV["SHOPIFY_ADMIN_ACCESS_TOKEN"],
        storefront_access_token: ENV["SHOPIFY_STOREFRONT_ACCESS_TOKEN"]
      )
    end
    let(:adapter) { described_class.new(client: client) }
    # "The Minimal Snowboard" on ucp-test-bc2vif1p.myshopify.com — 50 in
    # stock, availableForSale: true, confirmed live via the Admin API.
    #
    # Shopify genuinely needs two different ids for "the same" item —
    # get_product/search_catalog go through the Admin API's Product node
    # (existing_product_id), while create_checkout's cart_lines feeds
    # straight into Storefront's CartLineInput#merchandiseId, which takes a
    # ProductVariant GID (existing_variant_id) — see Mapper's top-of-file
    # note.
    let(:existing_product_id) { "gid://shopify/Product/8379425259567" }
    let(:existing_variant_id) { "gid://shopify/ProductVariant/45662494818351" }
  end
end

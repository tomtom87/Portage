# frozen_string_literal: true

require "spec_helper"

# The env-proxy behaviour itself is covered in portage-ucp's
# proxy_support_spec; this only pins that the admin API POST goes through
# Support::Connection on the :platform route.
RSpec.describe "env-proxy support via Support::Connection (portage-ucp-shopify)" do
  it "routes the admin GraphQL POST through Support::Connection on the :platform route" do
    client = Portage::Ucp::Shopify::Client.new(shop_domain: "shop.example.invalid", admin_access_token: "tok")
    expect(Portage::Ucp::Support::Connection).to receive(:start)
      .with(anything, hash_including(route: :platform)).and_raise(IOError)

    expect do
      client.send(:post, "/admin/api/2026-04/graphql.json", headers: {}, query: "{ shop { name } }", variables: {})
    end.to raise_error(IOError)
  end
end

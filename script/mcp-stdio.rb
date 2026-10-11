# Serves a Shopify store to MCP clients over stdio. Entry point for the
# ghcr.io/tomtom87/portage-ucp image listed on the MCP Registry.
#
#   SHOPIFY_SHOP_DOMAIN=your-shop.myshopify.com \
#   SHOPIFY_STOREFRONT_ACCESS_TOKEN=... ruby script/mcp-stdio.rb
#
# No authenticator is configured, so mutating tools (cart, checkout) reject
# every call and the server is read-only: catalog search and product lookups.
require "portage/ucp/shopify"

# stdout carries the MCP stream, so logs go to stderr.
Portage::Ucp.configure { |config| config.logger = Logger.new($stderr) }

client = Portage::Ucp::Shopify::Client.new(
  shop_domain: ENV.fetch("SHOPIFY_SHOP_DOMAIN"),
  storefront_access_token: ENV.fetch("SHOPIFY_STOREFRONT_ACCESS_TOKEN"),
  admin_access_token: ENV["SHOPIFY_ADMIN_ACCESS_TOKEN"]
)

server = Portage::Ucp::Mcp::Server.build(adapter: Portage::Ucp::Shopify::Adapter.new(client: client))
MCP::Server::Transports::StdioTransport.new(server).open

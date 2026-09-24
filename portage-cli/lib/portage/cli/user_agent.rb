require "portage/ucp/client"
require_relative "version"

module Portage
  module Cli
    # Every request this CLI makes — to a store, a search backend, a
    # payment handler, or a notify webhook — names itself, then the client
    # gem it speaks UCP through, so a merchant reading its logs sees
    # "portage-cli/... portage-ucp-client/... (+https://github.com/...)"
    # rather than Ruby's default and knows where to look.
    USER_AGENT = "portage-cli/#{VERSION} #{Portage::Ucp::Client::USER_AGENT}".freeze
    HTTP_HEADERS = { "User-Agent" => USER_AGENT }.freeze
  end
end

require "portage/ucp/webmcp"
require "logger"
require "rack/test"
require "webmock/rspec"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

WebMock.disable_net_connect!

# Mcp::Server logs every tool call; keep spec output readable.
Portage::Ucp.configuration.logger = Logger.new(nil)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_excluding(:node) unless NodeBrowser.available?
end

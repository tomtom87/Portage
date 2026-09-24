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
  # Drives a real headless Chrome via Ferrum against this gem's own Rack
  # app, so it needs Chrome/Chromium installed. Opt in with `REAL_BROWSER=1`
  # (excluded by default: slow, and not every CI box has a browser).
  config.filter_run_excluding(:real_browser) unless ENV["REAL_BROWSER"] == "1"
end

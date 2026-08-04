require "portage/cli"
require "portage/ucp"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end

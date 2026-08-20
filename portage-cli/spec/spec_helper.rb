require "portage/cli"
require "portage/ucp"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end

# Sets the given env vars for the duration of the block, restoring whatever
# was there before (including "was unset") no matter how the block exits.
def with_env(vars)
  previous = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  vars.each { |k, v| ENV[k] = v }
  yield
ensure
  previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

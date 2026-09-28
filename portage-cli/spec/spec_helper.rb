require "portage/cli"
require "portage/ucp"
require "portage/ucp/decision"
require "tmpdir"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  # `portage buy` records remote purchases in the transaction log, and reads
  # it for the rolling cap and velocity limit. A TransactionLog built with no
  # explicit store or path (Buy's default, PolicyGuard's, Dispatcher's) lands
  # in a per-example tmpdir, never the developer's ~/.portage/transactions.json.
  config.around do |example|
    Dir.mktmpdir do |dir|
      @transaction_log_path = File.join(dir, "transactions.json")
      @webmcp_mappings_path = File.join(dir, "webmcp_mappings.json")
      # Classifier::PATH — a file that (unlike the two above) usually
      # doesn't exist, so redirecting it to a tmpdir just means "no
      # ~/.portage/categories.yml override", never a real one leaking in.
      @classifier_user_path = File.join(dir, "categories.yml")
      example.run
    end
  end

  config.before do
    allow(Portage::Ucp::Support::TransactionLog).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: @transaction_log_path }.merge(kwargs) unless kwargs.key?(:store)
      original.call(**kwargs)
    end

    # Same reasoning as TransactionLog above: `Buy`'s Phase 2 WebMCP mapping
    # fallback (docs/plans/webmcp-universal-outbound.md) reads and can write
    # `Portage::Cli::WebmcpMappings.load`'s default path — redirect it to a
    # per-example tmpdir so no spec run ever touches the developer's real
    # ~/.portage/webmcp_mappings.json.
    allow(Portage::Cli::WebmcpMappings).to receive(:load).and_wrap_original do |original, **kwargs|
      kwargs = { path: @webmcp_mappings_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    # Classifier.categories_for reads ~/.portage/categories.yml by default
    # (Classifier::PATH) — redirect it the same way, so a developer machine
    # that happens to have one never changes a spec's result. The shipped
    # known-stores/categories.yml (KNOWN_PATH) is a repo asset, not a user
    # file, and stays real.
    allow(Portage::Cli::Classifier).to receive(:categories_for).and_wrap_original do |original, text, **kwargs|
      kwargs = { user_path: @classifier_user_path }.merge(kwargs) unless kwargs.key?(:user_path)
      original.call(text, **kwargs)
    end
  end

  # `Cli.apply_proxy_settings` (docs/plans/proxy-support.md Phase 2) sets
  # Portage::Ucp::Support::ProxyConfig.current process-wide — reset it after
  # every example so one test's resolved proxy config (or a Cli.run that
  # went through it) never leaks into the next, including specs (like
  # proxy_support_spec.rb) that construct Buy/Notifier/etc. directly and
  # expect ProxyConfig.current's own lazy `direct` default.
  config.after do
    Portage::Ucp::Support::ProxyConfig.current = nil
  end
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

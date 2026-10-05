require "tmpdir"
require "fileutils"

# Every default path in portage-cli and portage-ucp is `File.join(Dir.home,
# ".portage", ...)`, frozen into a constant when the library loads. Point HOME
# at a throwaway dir *before* requiring it, so whatever a spec builds without
# its own `path:` (History, DotEnv, PaymentMethods, the journal, ...) lands
# there, never in the developer's real ~/.portage. The per-example redirects
# below stay: they give each example a fresh, empty dir.
SUITE_HOME = Dir.mktmpdir("portage-home")
ENV["HOME"] = SUITE_HOME
at_exit { FileUtils.remove_entry(SUITE_HOME) }

require "portage/cli"
require "portage/ucp"
require "portage/ucp/decision"
require "stringio"
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
      # Index::Store/ProductStore — same reasoning: a spec that never
      # passes its own `path:`/`stores:`/`products:` (Doctor's default,
      # SearchBackends::Index's default, Cli.run_index_*'s own
      # `Index::Store.new`) must never read or write the developer's real
      # ~/.portage/index/{stores,products}.json.
      @index_stores_path = File.join(dir, "index", "stores.json")
      @index_products_path = File.join(dir, "index", "products.json")
      # Index::KnownCache — same reasoning again, plus one more: with no
      # cache file present a spec that exercises SearchBackends::Index/
      # Doctor/Index::Builder without stubbing KnownCache itself will try
      # one real fetch (WebMock's `disable_net_connect!` above turns that
      # into a swallowed failure, same as offline — never a real request).
      @known_stores_path = File.join(dir, "index", "known-stores.json")
      @probe_cache_path = File.join(dir, "discovery-cache.json")
      @known_products_path = File.join(dir, "index", "known-products.json")
      # Config/Policy — `portage setup`'s wizard (docs/plans/
      # buy-skill-and-local-browser.md Phase 4) is the first thing in
      # portage-cli to call Portage::Cli::Config.load and
      # Portage::Ucp::Policy.load with no explicit path from inside a
      # `Cli.run` call (Doctor#nothing_configured?, the wizard's Handoff/
      # Policy steps) — same reasoning as every redirect above: never the
      # developer's real ~/.portage/config.json or ~/.portage/policy.json.
      @config_path = File.join(dir, "config.json")
      @policy_path = File.join(dir, "policy.json")
      # Quotes — `portage buy --dry-run` saves one; never under the
      # developer's real ~/.portage/quotes/.
      @quotes_dir = File.join(dir, "quotes")
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

    allow(Portage::Cli::Index::Store).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: @index_stores_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    allow(Portage::Cli::Index::ProductStore).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: @index_products_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    # Doctor's default index_database — same reasoning as the two stores above.
    allow(Portage::Cli::Index::Database).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: Portage::Cli::Index::Database.path_for(@index_stores_path) }.merge(kwargs)
      original.call(**kwargs)
    end

    # Same as categories_for — Classifier.names_for (Phase 3's browser
    # import display) reads the same ~/.portage/categories.yml override.
    allow(Portage::Cli::Classifier).to receive(:names_for).and_wrap_original do |original, ids, **kwargs|
      kwargs = { user_path: @classifier_user_path }.merge(kwargs) unless kwargs.key?(:user_path)
      original.call(ids, **kwargs)
    end

    # ProbeCache — `portage browser import` (Phase 3) and every other
    # prober that builds one with no explicit `path:` must never read or
    # write the developer's real ~/.portage/discovery-cache.json.
    allow(Portage::Cli::ProbeCache).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: @probe_cache_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    allow(Portage::Cli::Index::KnownCache).to receive(:new).and_wrap_original do |original, **kwargs|
      original.call(stores_path: @known_stores_path, products_path: @known_products_path, **kwargs)
    end

    # SearchBackends::Index/Doctor/Index::Builder all fetch Index::KnownCache
    # lazily the first time they're asked for anything and no cache exists
    # yet (docs/plans/buy-skill-and-local-browser.md Phase 2c) — a spec
    # that exercises any of them with no cache present (the common case:
    # @known_stores_path/@known_products_path above never exist unless a
    # spec writes them) would otherwise fire one real GET against the real
    # jsdelivr URL. WebMock's own `disable_net_connect!` guard exception
    # (WebMock::NetConnectNotAllowedError) is a bare Exception subclass,
    # not a StandardError one, so KnownCache's `rescue StandardError`
    # (deliberately as narrow as every other network call in this CLI —
    # see SearchBackends/OfferSources::ShopifyCatalog) doesn't swallow it;
    # stubbing the real URLs to a plain 404 here means that lazy fetch
    # resolves the ordinary "no known cache" way instead, in every spec
    # that doesn't stub something else for these URLs itself.
    stub_request(:get, Portage::Cli::Index::KnownCache::STORES_URL).to_return(status: 404)
    stub_request(:get, Portage::Cli::Index::KnownCache::PRODUCTS_URL).to_return(status: 404)

    allow(Portage::Cli::Config).to receive(:load).and_wrap_original do |original, **kwargs|
      kwargs = { path: @config_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    allow(Portage::Cli::Quotes).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { dir: @quotes_dir }.merge(kwargs) unless kwargs.key?(:dir)
      original.call(**kwargs)
    end

    allow(Portage::Ucp::Policy).to receive(:load).and_wrap_original do |original, **kwargs|
      kwargs = { path: @policy_path }.merge(kwargs) unless kwargs.key?(:path)
      original.call(**kwargs)
    end

    # HumanPrompt (docs/plans/human-pick-and-approve.md Phase 2) — no spec
    # ever opens the real /dev/tty: by default there's "no controlling
    # terminal", so `--via auto` resolves to `agent` and `--via tty` fails
    # cleanly. A spec that wants a person at the terminal stubs
    # open_terminal to return a FakeTerminal (or injects `terminal:`).
    allow(Portage::Cli::HumanPrompt).to receive(:open_terminal).and_raise(Errno::ENXIO)

    # ProductPage — `pick --view`/`approve --view` never open a real browser.
    allow_any_instance_of(Portage::Cli::ProductPage).to receive(:system).and_return(true)
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

# A stand-in for /dev/tty (HumanPrompt's `terminal:`): answers each question
# with the next scripted line, and keeps everything written to it.
class FakeTerminal
  def initialize(*answers)
    @input = StringIO.new(answers.map { |answer| "#{answer}\n" }.join)
    @output = StringIO.new
  end

  def gets = @input.gets
  def print(*) = @output.print(*)
  def puts(*) = @output.puts(*)
  def written = @output.string
end

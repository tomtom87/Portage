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
      # Index::Store/ProductStore — same reasoning: a spec that never
      # passes its own `path:`/`stores:`/`products:` (Doctor's default,
      # SearchBackends::Index's default, Cli.run_index_*'s own
      # `Index::Store.new`) must never read or write the developer's real
      # ~/.portage/index/{stores,products}.json.
      @index_stores_path = File.join(dir, "index", "stores.json")
      @index_products_path = File.join(dir, "index", "products.json")
      @index_browser_path = File.join(dir, "index", "browser-import.json")
      # Index::KnownCache — same reasoning again, plus one more: with no
      # cache file present a spec that exercises SearchBackends::Index/
      # Doctor/Index::Builder without stubbing KnownCache itself will try
      # one real fetch (WebMock's `disable_net_connect!` above turns that
      # into a swallowed failure, same as offline — never a real request).
      @known_stores_path = File.join(dir, "index", "known-stores.json")
      @known_products_path = File.join(dir, "index", "known-products.json")
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

    allow(Portage::Cli::Index::Sources::Browser).to receive(:new).and_wrap_original do |original, **kwargs|
      kwargs = { path: @index_browser_path }.merge(kwargs) unless kwargs.key?(:path)
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
    stub_request(:get, Portage::Cli::KnownStoresUrl::STORES).to_return(status: 404)
    stub_request(:get, Portage::Cli::KnownStoresUrl::PRODUCTS).to_return(status: 404)
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

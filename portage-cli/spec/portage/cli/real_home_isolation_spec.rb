require "spec_helper"
require "etc"

# Every default path under ~/.portage must resolve into the suite's own tmp
# HOME (spec_helper.rb), so no example can write the developer's real files.
RSpec.describe "real ~/.portage isolation" do
  let(:real_portage_dir) { File.join(Etc.getpwuid.dir, ".portage") }

  {
    "History::PATH" => -> { Portage::Cli::History::PATH },
    "Quotes::DIR" => -> { Portage::Cli::Quotes::DIR },
    "ProbeCache::PATH" => -> { Portage::Cli::ProbeCache::PATH },
    "SearchBackends::Allowlist::PATH" => -> { Portage::Cli::SearchBackends::Allowlist::PATH },
    "DotEnv::DEFAULT_PATH" => -> { Portage::Cli::DotEnv::DEFAULT_PATH },
    "PaymentMethods::PATH" => -> { Portage::Cli::PaymentMethods::PATH },
    "Index::DIR" => -> { Portage::Cli::Index::DIR },
    "Index::Store::PATH" => -> { Portage::Cli::Index::Store::PATH },
    "Index::ProductStore::PATH" => -> { Portage::Cli::Index::ProductStore::PATH },
    "Index::KnownCache::STORES_PATH" => -> { Portage::Cli::Index::KnownCache::STORES_PATH },
    "Index::KnownCache::PRODUCTS_PATH" => -> { Portage::Cli::Index::KnownCache::PRODUCTS_PATH },
    "Config::PATH" => -> { Portage::Cli::Config::PATH },
    "Classifier::PATH" => -> { Portage::Cli::Classifier::PATH },
    "WebmcpMappings::PATH" => -> { Portage::Cli::WebmcpMappings::PATH },
    "BrowserProfile::Profile::ROOT" => -> { Portage::Cli::BrowserProfile::Profile::ROOT },
    "Ucp::Policy::PATH" => -> { Portage::Ucp::Policy::PATH },
    "Ucp::TransactionLog::FileStore::PATH" => -> { Portage::Ucp::Support::TransactionLog::FileStore::PATH },
    "Ucp::OrderLedger::FileStore::PATH" => -> { Portage::Ucp::Support::OrderLedger::FileStore::PATH }
  }.each do |name, path|
    it "keeps #{name} out of the real ~/.portage" do
      expect(path.call).not_to start_with(real_portage_dir)
    end
  end

  it "keeps the default idempotency store out of the real ~/.portage" do
    store = Portage::Ucp::Support::Idempotency::FileStore.new

    expect(store.instance_variable_get(:@path)).not_to start_with(real_portage_dir)
  end
end

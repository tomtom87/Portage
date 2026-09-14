require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::Support::Idempotency::FileStore do
  around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "idempotency.marshal") and example.run } }

  def store = described_class.new(path: @path)

  it "returns NOT_FOUND for a key that was never stored" do
    expect(store.fetch("missing")).to equal(Portage::Ucp::Support::Idempotency::NOT_FOUND)
    expect(store.include?("missing")).to be(false)
  end

  it "round-trips a stored value, including a domain value object" do
    value = Portage::Ucp::Money.new(amount_minor: 500, currency: "USD")

    store.store("k1", value)

    expect(store.fetch("k1")).to eq(value)
    expect(store.include?("k1")).to be(true)
  end

  it "memoizes a nil result rather than treating it as absent" do
    store.store("k1", nil)

    expect(store.fetch("k1")).to be_nil
    expect(store.include?("k1")).to be(true)
  end

  it "keeps different keys independent" do
    store.store("k1", "order-1")
    store.store("k2", "order-2")

    expect(store.fetch("k1")).to eq("order-1")
    expect(store.fetch("k2")).to eq("order-2")
  end

  it "chmods the file 0600 on write" do
    store.store("k1", "order-1")

    expect(File.stat(@path).mode & 0o777).to eq(0o600)
  end

  it "survives a fresh instance re-reading the file (simulating a new process)" do
    store.store("k1", "order-1")

    fresh = described_class.new(path: @path)
    expect(fresh.fetch("k1")).to eq("order-1")

    fresh.store("k2", "order-2")
    expect(store.fetch("k2")).to eq("order-2")
  end
end

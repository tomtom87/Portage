require "spec_helper"

RSpec.describe Portage::Ucp::Support::Idempotency do
  let(:mutator) do
    Class.new do
      include Portage::Ucp::Support::Idempotency

      attr_reader :calls

      def initialize = @calls = 0

      def charge(idempotency_key)
        dedup(idempotency_key) do
          @calls += 1
          "order-#{@calls}"
        end
      end
    end.new
  end

  it "runs the block once per key and replays the first result on a retry" do
    expect(mutator.charge("key-1")).to eq("order-1")
    expect(mutator.charge("key-1")).to eq("order-1")
    expect(mutator.calls).to eq(1)
  end

  it "treats a different key as a different call" do
    mutator.charge("key-1")
    expect(mutator.charge("key-2")).to eq("order-2")
  end

  it "replays a nil result rather than re-running the block" do
    nil_returner = Class.new do
      include Portage::Ucp::Support::Idempotency

      attr_reader :calls

      def initialize = @calls = 0

      def run(key)
        dedup(key) do
          @calls += 1
          nil
        end
      end
    end.new

    2.times { nil_returner.run("key") }
    expect(nil_returner.calls).to eq(1)
  end

  it "is private — dedup is adapter-internal, not part of the Adapter contract" do
    expect(mutator).not_to respond_to(:dedup)
  end

  it "delegates to an injected store instead of the default in-memory one" do
    store = Portage::Ucp::Support::Idempotency::MemoryStore.new
    mutator.idempotency_store = store

    mutator.charge("key-1")

    expect(store.include?("key-1")).to be(true)
  end

  it "falls back to Portage::Ucp.configuration.idempotency_provider when no store is injected" do
    configured_store = Portage::Ucp::Support::Idempotency::MemoryStore.new
    Portage::Ucp.configure { |c| c.idempotency_provider = configured_store }

    mutator.charge("key-1")

    expect(configured_store.include?("key-1")).to be(true)
  ensure
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end

  it "prefers an explicitly injected store over Portage::Ucp.configuration.idempotency_provider" do
    configured_store = Portage::Ucp::Support::Idempotency::MemoryStore.new
    injected_store = Portage::Ucp::Support::Idempotency::MemoryStore.new
    Portage::Ucp.configure { |c| c.idempotency_provider = configured_store }
    mutator.idempotency_store = injected_store

    mutator.charge("key-1")

    expect(injected_store.include?("key-1")).to be(true)
    expect(configured_store.include?("key-1")).to be(false)
  ensure
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end

  it "runs the block once when two threads race on the same key" do
    ready = Queue.new
    release = Queue.new

    racer = Class.new do
      include Portage::Ucp::Support::Idempotency

      attr_reader :calls

      def initialize = @calls = 0

      def charge(idempotency_key, ready, release)
        dedup(idempotency_key) do
          @calls += 1
          ready << true
          release.pop
          "order-#{@calls}"
        end
      end
    end.new

    threads = Array.new(2) { Thread.new { racer.charge("key-1", ready, release) } }

    ready.pop
    release << true
    release << true
    results = threads.map(&:value)

    expect(racer.calls).to eq(1)
    expect(results).to eq(%w[order-1 order-1])
  end
end

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
end

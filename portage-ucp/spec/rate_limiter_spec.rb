require "spec_helper"

RSpec.describe Portage::Ucp::NullRateLimiter do
  it "never limits, regardless of key or capability" do
    expect { described_class.new.check!("any-key", "dev.ucp.shopping.cart") }.not_to raise_error
  end
end

RSpec.describe Portage::Ucp::RateLimiter do
  it "is abstract — the base class raises if #check! isn't overridden" do
    expect { described_class.new.check!("key", "dev.ucp.shopping.cart") }.to raise_error(Portage::Ucp::NotImplementedError)
  end
end

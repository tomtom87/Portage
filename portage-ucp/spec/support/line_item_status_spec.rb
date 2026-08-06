require "spec_helper"

RSpec.describe Portage::Ucp::Support::LineItemStatus do
  it "reports a zero-quantity line as removed, whatever was fulfilled" do
    expect(described_class.derive(total: 0, fulfilled: 0)).to eq("removed")
  end

  it "reports a fully fulfilled line as fulfilled" do
    expect(described_class.derive(total: 3, fulfilled: 3)).to eq("fulfilled")
  end

  it "reports a partially fulfilled line as partial" do
    expect(described_class.derive(total: 3, fulfilled: 1)).to eq("partial")
  end

  it "reports an untouched line as processing" do
    expect(described_class.derive(total: 3, fulfilled: 0)).to eq("processing")
  end
end

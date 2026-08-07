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

  it "maps a platform status through its own table" do
    expect(described_class.from_table({ "complete" => "fulfilled" }, "complete")).to eq("fulfilled")
  end

  it "falls back to processing for a status the platform's table doesn't cover" do
    expect(described_class.from_table({ "complete" => "fulfilled" }, "some_new_status")).to eq("processing")
  end

  it "falls back to processing when the platform reports no status at all" do
    expect(described_class.from_table({ "complete" => "fulfilled" }, nil)).to eq("processing")
  end

  it "counts the whole line as fulfilled when the order-level status says so" do
    expect(described_class.fulfilled_quantity("fulfilled", 3)).to eq(3)
  end

  it "counts none of the line as fulfilled for any other status" do
    expect(described_class.fulfilled_quantity("partial", 3)).to eq(0)
  end
end

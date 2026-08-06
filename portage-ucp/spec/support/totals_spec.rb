require "spec_helper"

RSpec.describe Portage::Ucp::Support::Totals do
  describe ".summary" do
    it "builds subtotal and total in wire order" do
      expect(described_class.summary(subtotal: 1000, total: 1200).map(&:to_wire_h))
        .to eq([{ "type" => "subtotal", "amount" => 1000 }, { "type" => "total", "amount" => 1200 }])
    end

    it "inserts tax between subtotal and total when positive" do
      expect(described_class.summary(subtotal: 1000, total: 1200, tax: 200).map { |t| t.to_wire_h["type"] })
        .to eq(%w[subtotal tax total])
    end

    it "omits a zero or absent tax entry" do
      expect(described_class.summary(subtotal: 1000, total: 1000, tax: 0).length).to eq(2)
      expect(described_class.summary(subtotal: 1000, total: 1000, tax: nil).length).to eq(2)
    end
  end

  describe ".line" do
    it "reports the same amount as subtotal and total by default" do
      expect(described_class.line(450).map(&:to_wire_h))
        .to eq([{ "type" => "subtotal", "amount" => 450 }, { "type" => "total", "amount" => 450 }])
    end

    it "takes a discounted total separately" do
      expect(described_class.line(500, 450).map { |t| t.to_wire_h["amount"] }).to eq([500, 450])
    end
  end
end

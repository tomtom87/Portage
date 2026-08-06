require "spec_helper"

RSpec.describe Portage::Ucp::Support::Amounts do
  describe ".decimal_to_minor" do
    it "scales a decimal string to integer minor units" do
      expect(described_class.decimal_to_minor("12.50")).to eq(1250)
    end

    it "accepts numerics as well as strings" do
      expect(described_class.decimal_to_minor(12.5)).to eq(1250)
    end

    it "truncates sub-minor-unit precision rather than rounding up" do
      expect(described_class.decimal_to_minor("0.999")).to eq(99)
    end

    it "treats an omitted amount as zero" do
      expect(described_class.decimal_to_minor(nil)).to eq(0)
      expect(described_class.decimal_to_minor("")).to eq(0)
    end
  end

  describe ".subunits_to_minor" do
    it "parses an already-minor-unit string without scaling it" do
      expect(described_class.subunits_to_minor("500")).to eq(500)
    end

    it "treats an omitted amount as zero" do
      expect(described_class.subunits_to_minor(nil)).to eq(0)
    end
  end

  describe ".money" do
    it "builds a Money in minor units with the given currency" do
      expect(described_class.money("9.99", "USD"))
        .to eq(Portage::Ucp::Money.new(amount_minor: 999, currency: "USD"))
    end
  end
end

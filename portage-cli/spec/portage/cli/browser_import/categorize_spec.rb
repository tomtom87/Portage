require "spec_helper"

RSpec.describe Portage::Cli::BrowserImport::Categorize do
  describe ".domain" do
    # 17 categories weighted 1-3 by visits, six of them tied at 3. With this
    # many, `sort_by` on the weight alone puts 16 and 14 ahead of 3 and 4 and
    # drops 12, so the top five is not the first five seen.
    let(:weights) { [2, 2, 1, 3, 3, 1, 1, 2, 1, 1, 1, 1, 3, 3, 3, 2, 3] }
    let(:rows) do
      weights.each_index.map { |i| { url: "https://shop.example/", title: "t#{i}", folder: "", visits: weights[i] } }
    end

    before do
      allow(Portage::Cli::Classifier).to receive(:categories_for) { |text| [text.delete_prefix("t")] }
    end

    it "keeps equally weighted categories in first-seen order" do
      expect(described_class.domain(rows).keys).to eq(%w[3 4 12 13 14])
    end
  end
end

require "spec_helper"

RSpec.describe Portage::Ucp::Support::OfferRanking do
  def rank(offers)
    described_class.rank(offers) { |offer| [offer[:buyable], offer[:amount]] }.map { |offer| offer[:id] }
  end

  it "ranks buyable offers before browse-only ones, whatever the price" do
    expect(rank([{ id: :cheap_browse_only, buyable: false, amount: 100 },
                 { id: :pricier_buyable, buyable: true, amount: 500 }]))
      .to eq(%i[pricier_buyable cheap_browse_only])
  end

  it "ranks cheaper offers first among buyable ones" do
    expect(rank([{ id: :expensive, buyable: true, amount: 500 }, { id: :cheap, buyable: true, amount: 100 }]))
      .to eq(%i[cheap expensive])
  end

  it "puts unpriced offers after priced ones" do
    expect(rank([{ id: :unpriced, buyable: true, amount: nil }, { id: :priced, buyable: true, amount: 100 }]))
      .to eq(%i[priced unpriced])
  end

  it "keeps ties in input order" do
    expect(rank([{ id: :first, buyable: true, amount: 100 }, { id: :second, buyable: true, amount: 100 }]))
      .to eq(%i[first second])
  end

  it "reads each offer through the block, so any shape ranks" do
    ranked = described_class.rank([[:b, 200], [:a, 100]]) { |(_id, amount)| [true, amount] }

    expect(ranked).to eq([[:a, 100], [:b, 200]])
  end
end

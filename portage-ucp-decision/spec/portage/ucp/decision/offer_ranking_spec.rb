require "spec_helper"

RSpec.describe Portage::Ucp::Decision::OfferRanking do
  let(:candidate_class) { described_class::Candidate }

  it "delegates the rule to Portage::Ucp::Support::OfferRanking" do
    allow(Portage::Ucp::Support::OfferRanking).to receive(:rank).and_call_original
    candidates = [candidate_class.new(offer: :only, buyable: true, amount: 100)]

    described_class.call(candidates)

    expect(Portage::Ucp::Support::OfferRanking).to have_received(:rank).with(candidates)
  end

  it "ranks buyable offers before non-buyable ones regardless of price" do
    cheap_unbuyable = candidate_class.new(offer: :cheap_unbuyable, buyable: false, amount: 100)
    pricier_buyable = candidate_class.new(offer: :pricier_buyable, buyable: true, amount: 500)

    ranked = described_class.call([cheap_unbuyable, pricier_buyable])

    expect(ranked.map(&:offer)).to eq(%i[pricier_buyable cheap_unbuyable])
  end

  it "ranks cheaper offers first among buyable candidates" do
    expensive = candidate_class.new(offer: :expensive, buyable: true, amount: 500)
    cheap = candidate_class.new(offer: :cheap, buyable: true, amount: 100)

    ranked = described_class.call([expensive, cheap])

    expect(ranked.map(&:offer)).to eq(%i[cheap expensive])
  end

  it "puts unpriced offers after priced ones" do
    unpriced = candidate_class.new(offer: :unpriced, buyable: true, amount: nil)
    priced = candidate_class.new(offer: :priced, buyable: true, amount: 100)

    ranked = described_class.call([unpriced, priced])

    expect(ranked.map(&:offer)).to eq(%i[priced unpriced])
  end

  it "is stable for ties" do
    first = candidate_class.new(offer: :first, buyable: true, amount: 100)
    second = candidate_class.new(offer: :second, buyable: true, amount: 100)

    ranked = described_class.call([first, second])

    expect(ranked.map(&:offer)).to eq(%i[first second])
  end
end

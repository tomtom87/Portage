require "spec_helper"

# Both paths — portage-ucp-decision installed, and absent — run against the
# same cases, so the built-in fallbacks can't drift from the gem's rules.
RSpec.describe Portage::Cli::Decisions do
  before { allow(Portage::Ucp::Policy).to receive(:load).and_return(policy) }

  let(:policy) { Portage::Ucp::Policy.new(data: {}) }

  it "finds the decision gem in the dev bundle" do
    expect(described_class.available?).to be true
  end

  { "with portage-ucp-decision installed" => true, "without portage-ucp-decision" => false }.each do |label, installed|
    context label do
      before { allow(described_class).to receive(:available?).and_return(installed) }

      describe ".rank" do
        it "puts buyable first, then cheapest, then unpriced, keeping ties stable" do
          offers = [{ id: 1, checkout: false, amount: 100 }, { id: 2, checkout: true, amount: nil },
                    { id: 3, checkout: true, amount: 500 }, { id: 4, checkout: true, amount: 200 },
                    { id: 5, checkout: true, amount: 200 }]

          expect(described_class.rank(offers).map { |o| o[:id] }).to eq([4, 5, 3, 2, 1])
        end
      end

      describe ".escalation" do
        it "escalates requires_escalation" do
          expect(described_class.escalation(checkout_status: "requires_escalation"))
            .to eq(escalate: true, reason: :requires_escalation)
        end

        it "escalates on a warning, with the status winning over it" do
          expect(described_class.escalation(checkout_status: "ready_for_complete", warnings: ["dropped"]))
            .to eq(escalate: true, reason: :mismatch)
          expect(described_class.escalation(checkout_status: "requires_escalation", warnings: ["dropped"]))
            .to eq(escalate: true, reason: :requires_escalation)
        end

        it "keeps going otherwise" do
          expect(described_class.escalation(checkout_status: "ready_for_complete"))
            .to eq(escalate: false, reason: nil)
        end
      end

      describe ".policy" do
        def check(**overrides)
          described_class.policy(amount: 5000, currency: "USD", merchant: "shop.example", token_ref: "ref",
                                 **overrides)
        end

        it "allows everything under an empty policy" do
          expect(check).to eq(allowed: true, reason: nil)
        end

        context "with a per-transaction cap" do
          let(:policy) { Portage::Ucp::Policy.new(data: { "per_transaction_cap" => { "amount" => 1000, "currency" => "USD" } }) }

          it "denies over the cap" do
            expect(check).to eq(allowed: false, reason: :per_transaction_cap_exceeded)
          end

          it "denies a checkout with no total, rather than skipping the cap" do
            expect(check(amount: nil)).to eq(allowed: false, reason: :total_unknown)
          end
        end

        it "allows a checkout with no total when no cap is configured" do
          expect(check(amount: nil)).to eq(allowed: true, reason: nil)
        end

        context "with a merchant allowlist" do
          let(:policy) { Portage::Ucp::Policy.new(data: { "merchant_allowlist" => ["other.example"] }) }

          it "denies a merchant not on it" do
            expect(check).to eq(allowed: false, reason: :merchant_not_allowlisted)
          end
        end
      end
    end
  end
end

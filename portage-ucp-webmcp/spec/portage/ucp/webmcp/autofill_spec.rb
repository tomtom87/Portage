require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Autofill do
  # A bridge that answers #autofill/#headless? — everything a real
  # Bridges::ScriptEvaluator would offer, without a real browser (the plan's
  # own posture for Phase 3: "filling logic against a fake/stubbed bridge,
  # no real browser needed for most cases").
  def fake_bridge(headless: false, page_result: nil)
    result = page_result
    Class.new do
      define_method(:headless?) { headless }
      define_method(:autofill) { |_fields, **_kwargs| result }
    end.new
  end

  it "fills fields and reports what matched/didn't, on a headed bridge" do
    bridge = fake_bridge(headless: false,
                         page_result: { "blocked" => nil, "filled" => ["email"], "unmatched" => ["shipping tel"],
                                        "rate" => ["Standard shipping"] })

    result = described_class.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).to eq(:filled)
    expect(result).to be_ok
    expect(result.filled).to eq(["email"])
    expect(result.unmatched).to eq(["shipping tel"])
    expect(result.rate).to eq(["Standard shipping"])
  end

  it "reports needs_headed_browser without touching the page when the bridge is headless" do
    bridge = fake_bridge(headless: true)
    expect(bridge).not_to receive(:autofill)

    result = described_class.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).to eq(:needs_headed_browser)
    expect(result.unmatched).to eq(["email"])
    expect(result).not_to be_ok
  end

  it "treats a bridge that never says whether it's headless as headless (safe default)" do
    bridge = Class.new { define_method(:autofill) { |*| raise "should not be called" } }.new

    result = described_class.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).to eq(:needs_headed_browser)
  end

  it "reports unsupported for a bridge with no #autofill at all, never raising" do
    bridge = Class.new { define_method(:headless?) { false } }.new

    result = described_class.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).to eq(:unsupported)
    expect(result.unmatched).to eq(["email"])
  end

  it "reports blocked, with nothing filled, when the page script signals a challenge/CAPTCHA" do
    bridge = fake_bridge(headless: false,
                         page_result: { "blocked" => "captcha", "filled" => [], "unmatched" => ["email"],
                                        "rate" => [] })

    result = described_class.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).to eq(:blocked)
    expect(result.filled).to be_empty
  end

  it "does nothing and reports filled/empty when there are no fields to fill" do
    bridge = fake_bridge(headless: false)
    expect(bridge).not_to receive(:autofill)

    result = described_class.call(bridge: bridge, fields: {})

    expect(result.outcome).to eq(:filled)
    expect(result.filled).to be_empty
    expect(result.unmatched).to be_empty
  end

  it "passes fields and a preset's fallback selectors straight through to the bridge" do
    bridge = fake_bridge(headless: false, page_result: { "blocked" => nil, "filled" => [], "unmatched" => [],
                                                         "rate" => [] })
    expect(bridge).to receive(:autofill).with({ "email" => "a@example.com" }, selectors: { "email" => "#email" })
                                        .and_return({ "blocked" => nil, "filled" => [], "unmatched" => [],
                                                      "rate" => [] })

    described_class.call(bridge: bridge, fields: { "email" => "a@example.com" }, selectors: { "email" => "#email" })
  end
end

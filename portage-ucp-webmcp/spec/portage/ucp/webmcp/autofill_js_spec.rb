require "spec_helper"

# assets/autofill.js itself, run through the real ScriptEvaluator#autofill
# in a node tab (spec/support/node_browser.js) holding a fake checkout page
# (spec/support/fake_checkout_dom.js). autofill_spec.rb covers the Ruby gate
# with a stubbed bridge; this is the half that stub never exercised, which
# is how an unparseable autofill.js once passed every spec (design-log §51).
RSpec.describe "assets/autofill.js against a checkout page" do
  let(:evaluator) { Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.new(evaluate: ->(js) { browser.evaluate(js) }) }

  before { skip "node isn't on PATH — can't run autofill.js" unless NodeBrowser.available? }
  after { @browser&.close }

  def browser = @browser ||= NodeBrowser.new

  def install(elements, title: "Checkout")
    browser.evaluate(File.read(File.expand_path("../../../support/fake_checkout_dom.js", __dir__), encoding: "UTF-8"))
    browser.evaluate("FakeCheckout.install(#{JSON.generate(title: title, elements: elements)})")
  end

  def snapshot
    JSON.parse(browser.evaluate("JSON.stringify(FakeCheckout.snapshot())"))
  end

  def element(attr, value)
    snapshot.find { |el| el["attrs"][attr] == value }
  end

  def radio(id) = { tag: "input", attrs: { type: "radio", name: "shipping_rate", id: id } }
  def label(id, text) = { tag: "label", attrs: { for: id }, text: text }

  describe "text fields" do
    it "fills by autocomplete, dispatching input and change, and leaves payment/hidden/password alone" do
      install([{ tag: "input", attrs: { autocomplete: "email", type: "email" } },
               { tag: "input", attrs: { autocomplete: "cc-number", name: "card" } },
               { tag: "input", attrs: { type: "hidden", autocomplete: "shipping postal-code", name: "h" } },
               { tag: "input", attrs: { autocomplete: "shipping postal-code", name: "zip" } }])

      result = evaluator.autofill({ "email" => "a@example.com", "shipping postal-code" => "S40 1AA",
                                    "cc-number" => "4242" })

      expect(result).to include("blocked" => nil, "filled" => ["email", "shipping postal-code"],
                                "unmatched" => ["cc-number"])
      expect(element("autocomplete", "email")).to include("value" => "a@example.com",
                                                          "events" => %w[input change])
      expect(element("name", "zip")["value"]).to eq("S40 1AA")
      expect(element("name", "card")).to include("value" => "", "events" => [])
      expect(element("name", "h")).to include("value" => "", "events" => [])
    end

    it "stops as blocked on a challenge page without touching a field" do
      install([{ tag: "input", attrs: { autocomplete: "email" } }], title: "Just a moment...")

      result = evaluator.autofill({ "email" => "a@example.com" })

      expect(result).to include("blocked" => "captcha", "filled" => [], "unmatched" => ["email"])
      expect(element("autocomplete", "email")["events"]).to be_empty
    end
  end

  describe "a <select> reached through a preset's checkout_selectors" do
    let(:country_select) do
      { tag: "select", attrs: { name: "countryCode" },
        options: [{ value: "", text: "Choose" }, { value: "GB", text: "United Kingdom" },
                  { value: "TH", text: "Thailand" }] }
    end
    let(:selectors) { { "shipping country" => "select[name='countryCode']" } }

    it "matches an option by value" do
      install([country_select])

      result = evaluator.autofill({ "shipping country" => "GB" }, selectors: selectors)

      expect(result["filled"]).to eq(["shipping country"])
      expect(element("name", "countryCode")).to include("value" => "GB", "events" => %w[input change])
    end

    it "matches an option by visible text, case-insensitive and trimmed" do
      install([country_select])

      result = evaluator.autofill({ "shipping country" => "  united kingdom " }, selectors: selectors)

      expect(result["filled"]).to eq(["shipping country"])
      expect(element("name", "countryCode")["value"]).to eq("GB")
    end

    it "reports the field unmatched, without throwing or changing it, when no option matches" do
      install([country_select])

      result = evaluator.autofill({ "shipping country" => "Narnia" }, selectors: selectors)

      expect(result).to include("filled" => [], "unmatched" => ["shipping country"])
      expect(element("name", "countryCode")).to include("value" => "", "events" => [])
    end
  end

  describe "cheapest rate" do
    it "picks the cheapest of several rates, in any currency symbol or ISO code" do
      install([label("r1", "Express ฿1,950.00"), radio("r1"),
               label("r2", "Standard ฿450.00"), radio("r2"),
               label("r3", "Next day THB 2,400"), radio("r3")])

      result = evaluator.autofill({})

      expect(result["rate"]).to eq(["Standard ฿450.00"])
      expect(element("id", "r2")).to include("checked" => true, "events" => %w[input change])
      expect(element("id", "r1")["checked"]).to be(false)
    end

    it "reads a code or symbol after the amount, and thousands separators, as the full price" do
      install([label("r1", "Freight 1.950,00 EUR"), radio("r1"),
               label("r2", "Courier 12,50 €"), radio("r2")])

      expect(evaluator.autofill({})["rate"]).to eq(["Courier 12,50 €"])
    end

    it "still treats a Free rate as the cheapest" do
      install([label("r1", "Standard £4.99"), radio("r1"), label("r2", "Free collection"), radio("r2")])

      expect(evaluator.autofill({})["rate"]).to eq(["Free collection"])
    end

    it "leaves a single rate alone — there's nothing to choose" do
      install([label("r1", "Standard £50.00"), radio("r1")])

      expect(evaluator.autofill({})["rate"]).to eq([])
      expect(element("id", "r1")["events"]).to be_empty
    end
  end
end

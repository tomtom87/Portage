require "spec_helper"

RSpec.describe Portage::Cli::ConfidenceState do
  let(:request) { { query: "tee", merchant: "shop.example", quantity: 1, item_id: "v1", item_title: "Tee" } }

  it "copies only allowlisted fields, whatever else the checkout carries" do
    checkout = { "status" => "ready_for_complete", "currency" => "USD", "buyer" => { "email" => "a@b.example" },
                 "payment" => { "token" => "tok_1" }, "continue_url" => "https://shop.example/c",
                 "line_items" => [{ "item" => { "id" => "v1", "title" => "Tee", "price" => 1000, "sku" => "x" },
                                    "quantity" => 1, "buyer_note" => "call +15555550100" }] }

    state = described_class.build(request: request, checkout: checkout, warnings: [])

    expect(state["checkout"].keys).to eq(%w[status currency line_items totals discounts shipping])
    expect(state["checkout"]["line_items"].first.keys)
      .to eq(%w[item_id title unit_price quantity totals requested])
    expect(JSON.generate(state)).not_to include("a@b.example", "tok_1", "shop.example/c", "+15555550100", "sku")
  end

  it "drops nested objects a store put where a scalar belongs, and cuts long strings" do
    checkout = { "status" => { "address" => "1 Main St" }, "currency" => "USD",
                 "line_items" => [{ "item" => { "id" => "v1", "title" => "x" * 5000, "price" => [1] },
                                    "quantity" => 1 }] }

    state = described_class.build(request: request, checkout: checkout, warnings: [])
    line = state["checkout"]["line_items"].first

    expect(state["checkout"]["status"]).to be_nil
    expect(line["unit_price"]).to be_nil
    expect(line["title"].length).to eq(described_class::MAX_STRING)
  end

  it "tolerates a checkout with malformed or missing parts" do
    checkout = { "line_items" => ["junk", { "item" => "junk" }], "totals" => "junk", "discounts" => [],
                 "fulfillment" => { "methods" => [{ "groups" => ["junk"] }] } }

    state = described_class.build(request: request, checkout: checkout, warnings: nil)

    expect(state["checkout"]["line_items"].map { |line| line["requested"] }).to eq([false, false])
    expect(state["checkout"].values_at("totals", "discounts", "shipping")).to eq([[], [], []])
    expect(state["warnings"]).to eq([])
  end

  it "adds approved_quote only when given one" do
    quote = { store: "https://shop.example", product_id: "v1", title: "Tee", quantity: 1, total: 1000,
              currency: "USD", secret: "never" }

    with_quote = described_class.build(request: request, checkout: {}, warnings: [], quote: quote)
    without = described_class.build(request: request, checkout: {}, warnings: [])

    expect(with_quote["approved_quote"]).to eq("store" => "https://shop.example", "product_id" => "v1",
                                               "title" => "Tee", "quantity" => 1, "total" => 1000,
                                               "currency" => "USD")
    expect(without).not_to have_key("approved_quote")
  end
end

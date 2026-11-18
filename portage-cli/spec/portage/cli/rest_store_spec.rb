require "spec_helper"

# End to end against a stubbed REST-only store (the #178 shape: one `rest`
# service, no `mcp`), with only HTTP faked — docs/plans/ucp-rest-transport.md.
RSpec.describe "a REST-only UCP store" do
  let(:store) { "https://shop.example" }
  let(:endpoint) { "#{store}/ucp/2026-08-25" }
  let(:json) { { "Content-Type" => "application/json" } }
  let(:manifest) do
    path = File.expand_path("../../../../portage-ucp-client/spec/fixtures/rest_only_manifest.json", __dir__)
    JSON.parse(File.read(path)).tap do |m|
      m["ucp"]["services"]["dev.ucp.shopping"][0]["endpoint"] = endpoint
      m["ucp"]["capabilities"]["dev.ucp.shopping.cart"] = [{ "version" => "2026-08-25" }]
    end
  end
  let(:product) do
    { "id" => "p1", "title" => "Cold Brew", "url" => "#{store}/p1",
      "price_range" => { "min" => { "amount" => 2400, "currency" => "USD" } } }
  end
  let(:checkout) do
    { "id" => "chk_1", "status" => "ready_for_complete", "currency" => "USD", "totals" => [], "links" => [],
      "continue_url" => "#{store}/checkout/chk_1",
      "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1 }] }
  end

  before do
    allow(Portage::Cli::PaymentMethods).to receive(:default).and_return(nil)
    allow(Portage::Ucp::Policy).to receive(:load).and_return(Portage::Ucp::Policy.new(data: {}))
    stub_request(:get, "#{store}/.well-known/ucp").to_return(status: 200, body: manifest.to_json)
    stub_request(:post, "#{endpoint}/catalog/search")
      .to_return(status: 200, body: { "products" => [product] }.to_json, headers: json)
  end

  def buy = Portage::Cli::Buy.new(url: "shop.example", query: "cold", yes: true, payment_token: "tok_1")

  it "buy checks out and completes over REST" do
    stub = stub_request(:post, "#{endpoint}/checkout-sessions")
           .with(headers: { "UCP-Agent" => /profile=/ }).to_return(status: 201, body: checkout.to_json, headers: json)
    complete = stub_request(:post, "#{endpoint}/checkout-sessions/chk_1/complete")
               .with(headers: { "UCP-Agent" => /profile=/ })
               .to_return(status: 200, body: checkout.merge("status" => "completed").to_json, headers: json)

    report = buy.call

    expect([stub, complete]).to all(have_been_requested)
    expect(report).to include(source: "native_ucp", outcome: "purchased")
  end

  it "buy prints the store's HTTP status and own text when REST refuses the checkout" do
    stub_request(:post, "#{endpoint}/checkout-sessions").to_return(
      status: 403, body: { "messages" => [{ "content" => "Invalid API key" }] }.to_json, headers: json
    )

    report = buy.call

    expect(report[:outcome]).to eq("store_refused")
    expect(report[:message]).to include("HTTP 403: Invalid API key")
  end

  it "buy keeps the store's text when REST refuses completion for lack of permission" do
    stub_request(:post, "#{endpoint}/checkout-sessions").to_return(status: 201, body: checkout.to_json, headers: json)
    stub_request(:post, "#{endpoint}/checkout-sessions/chk_1/complete").to_return(
      status: 403, body: { "messages" => [{ "content" => "Forbidden: agent not enabled" }] }.to_json, headers: json
    )

    report = buy.call

    expect(report[:outcome]).to eq("permission_denied")
    expect(report[:message]).to include("HTTP 403: Forbidden: agent not enabled")
  end

  it "find searches the catalog over REST" do
    backend = Object.new
    allow(backend).to receive_messages(name: "stub", available?: true, search: [store])
    cache = instance_double(Portage::Cli::ProbeCache, fetch: nil, record: true)

    report = Portage::Cli::Find.new(query: "cold brew", cache: cache, throttle: 0, offer_sources: [],
                                    backends: [backend]).call

    expect(report[:offers].map { |o| o[:title] }).to eq(["Cold Brew"])
  end

  it "check reports the store as automated" do
    report = Portage::Cli::Check.call(store)

    expect(report[:verdict]).to eq("automated")
  end
end

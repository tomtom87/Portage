require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Quotes do
  around do |example|
    Dir.mktmpdir { |dir| @dir = File.join(dir, "nested", "quotes") and example.run }
  end

  def quotes(now: Time.now) = described_class.new(dir: @dir, now: now)

  def create(**fields)
    quotes(now: Time.at(1_700_000_000)).create(store: "https://shop.example", product_id: "p1", qty: 2,
                                               total: 4800, currency: "USD", query: "cold", **fields)
  end

  it "saves an unapproved quote under a qt_ id, one file per quote" do
    quote = create(offer_ref: "of_aaaaaa")

    expect(quote["quote_id"]).to match(/\Aqt_[0-9a-f]{12}\z/)
    expect(quotes.find(quote["quote_id"])).to eq(
      "quote_id" => quote["quote_id"], "offer_ref" => "of_aaaaaa", "store" => "https://shop.example",
      "product_id" => "p1", "query" => "cold", "qty" => 2, "total" => 4800, "currency" => "USD",
      "title" => nil, "url" => nil, "created_at" => 1_700_000_000, "approved" => false
    )
    expect(File).to exist(File.join(@dir, "#{quote['quote_id']}.json"))
  end

  it "returns nil for an unknown id, and never reads outside its directory" do
    expect(quotes.find("qt_000000000000")).to be_nil
    expect(quotes.find("../history")).to be_nil
  end

  it "stamps a quote used rather than deleting it" do
    id = create["quote_id"]

    quotes(now: Time.at(1_700_000_500)).consume(id)

    expect(quotes.find(id)).to include("used_at" => 1_700_000_500, "total" => 4800)
  end

  it "keeps the title and product page it was given" do
    quote = create(title: "Cold Brew", url: "https://shop.example/products/cold")

    expect(quotes.find(quote["quote_id"])).to include("title" => "Cold Brew", "url" => "https://shop.example/products/cold")
  end

  it "records who approved a quote, and when" do
    id = create["quote_id"]

    approved = quotes(now: Time.at(1_700_000_100)).approve(id, by: "agent_relayed")

    expect(approved).to include("approved" => true, "approved_by" => "agent_relayed", "approved_at" => 1_700_000_100)
    expect(quotes.find(id)).to include("approved_by" => "agent_relayed")
  end

  it "never lets a relayed yes downgrade the person's own approval" do
    id = create["quote_id"]
    quotes.approve(id, by: "person")

    expect(quotes.approve(id, by: "agent_relayed")).to include("approved_by" => "person")
    expect(quotes.find(id)).to include("approved_by" => "person")
  end

  it "returns nil when approving an unknown quote" do
    expect(quotes.approve("qt_000000000000", by: "person")).to be_nil
  end

  it "ignores consuming an unknown quote" do
    expect { quotes.consume("qt_000000000000") }.not_to raise_error
  end

  it "returns nil rather than raising when it can't write" do
    allow(File).to receive(:write).and_raise(Errno::EACCES)

    expect(create).to be_nil
  end
end

require "spec_helper"

RSpec.describe Portage::Cli do
  let(:report) do
    { url: "https://shop.example", source: "native_ucp", browse: true, checkout: true,
      products: [{ "id" => "p1", "title" => "Cold Brew" }], checkout_url: nil, message: "ok" }
  end

  describe ".run" do
    it "prints usage and returns 1 for an unknown command" do
      expect { expect(described_class.run(["nope"])).to eq(1) }.to output.to_stderr
    end

    it "prints usage and returns 1 when buy has no url" do
      expect { expect(described_class.run(["buy"])).to eq(1) }.to output.to_stderr
    end

    it "dispatches buy to Portage::Cli::Buy with the parsed options" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      described_class.run(%w[buy shop.example --query cold --qty 2 --payment-token tok --yes --dry-run])

      expect(captured).to include(url: "shop.example", query: "cold", qty: 2, payment_token: "tok",
                                  yes: true, dry_run: true)
    end

    it "prints JSON when --json is given, and strips :json before building Buy" do
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }

      output = nil
      expect { output = capture_stdout { described_class.run(%w[buy shop.example --json]) } }.not_to raise_error

      expect(captured).not_to have_key(:json)
      expect(JSON.parse(output)["source"]).to eq("native_ucp")
    end

    it "returns 0 when the report has browse or checkout, 1 otherwise" do
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: report))
      expect(described_class.run(%w[buy shop.example])).to eq(0)

      dead_end = report.merge(browse: false, checkout: false)
      allow(Portage::Cli::Buy).to receive(:new).and_return(instance_double(Portage::Cli::Buy, call: dead_end))
      expect(described_class.run(%w[buy shop.example])).to eq(1)
    end
  end

  describe "find" do
    let(:offer) do
      { store: "https://shop.example", source: "duckduckgo", checkout: true,
        product_id: "p1", title: "Cold Brew", amount: 2400, currency: "USD", url: nil }
    end
    let(:found) { { query: "cold", candidates: [], stores: [], offers: [offer], message: "Found 1 offer(s)." } }

    def stub_find(result)
      captured = nil
      allow(Portage::Cli::Find).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Find, call: result)
      }
      -> { captured }
    end

    it "requires a query" do
      expect { expect(described_class.run(["find"])).to eq(1) }.to output.to_stderr
    end

    it "prints the ranked offers and exits 0" do
      stub_find(found)

      output = capture_stdout { expect(described_class.run(["find", "--query", "cold"])).to eq(0) }

      expect(output).to include("Found 1 offer(s).", "https://shop.example", "Cold Brew", "24.00 USD")
    end

    it "marks browse-only offers and unknown prices" do
      stub_find(found.merge(offers: [offer.merge(checkout: false, amount: nil, currency: nil)]))

      output = capture_stdout { described_class.run(["find", "--query", "cold"]) }

      expect(output).to include("price n/a", "browse only")
    end

    it "exits 1 when nothing was found" do
      stub_find(found.merge(offers: []))

      capture_stdout { expect(described_class.run(["find", "--query", "cold"])).to eq(1) }
    end

    it "converts --max-price from major to minor units" do
      captured = stub_find(found)

      capture_stdout { described_class.run(["find", "--query", "cold", "--max-price", "24.50", "--limit", "3"]) }

      expect(captured.call).to include(query: "cold", max_price: 2450, limit: 3)
    end
  end

  describe "buy without a url" do
    let(:offer) do
      { store: "https://shop.example", source: "duckduckgo", checkout: true,
        product_id: "p1", title: "Cold Brew", amount: 2400, currency: "USD", url: nil }
    end
    let(:found) { { query: "cold", candidates: [], stores: [], offers: [offer], message: "Found 1 offer(s)." } }

    before { allow($stdin).to receive(:tty?).and_return(false) }

    def stub_buy
      captured = nil
      allow(Portage::Cli::Buy).to receive(:new) { |**opts|
        captured = opts
        instance_double(Portage::Cli::Buy, call: report)
      }
      -> { captured }
    end

    it "buys directly from --store without searching at all" do
      captured = stub_buy
      allow(Portage::Cli::Find).to receive(:new)

      capture_stdout { described_class.run(["buy", "--query", "cold", "--store", "https://shop.example", "--yes"]) }

      expect(captured.call).to include(url: "https://shop.example", query: "cold", yes: true)
      expect(Portage::Cli::Find).not_to have_received(:new)
    end

    it "lists offers but refuses to buy when the run isn't interactive" do
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      allow(Portage::Cli::Buy).to receive(:new)

      output = capture_stdout { expect(described_class.run(["buy", "--query", "cold", "--yes"])).to eq(0) }

      expect(output).to include("Cold Brew")
      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "buys the picked offer by product id when a human picks one" do
      allow($stdin).to receive_messages(tty?: true, gets: "1\n")
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      captured = stub_buy

      capture_stdout { described_class.run(["buy", "--query", "cold", "--yes"]) }

      expect(captured.call).to include(url: "https://shop.example", product_id: "p1", query: "cold")
    end

    it "quits without buying on an empty or out-of-range pick" do
      allow($stdin).to receive_messages(tty?: true, gets: "\n")
      allow(Portage::Cli::Find).to receive(:new).and_return(instance_double(Portage::Cli::Find, call: found))
      allow(Portage::Cli::Buy).to receive(:new)

      capture_stdout { described_class.run(["buy", "--query", "cold"]) }

      expect(Portage::Cli::Buy).not_to have_received(:new)
    end

    it "still needs a url or a query" do
      expect { expect(described_class.run(["buy", "--yes"])).to eq(1) }.to output.to_stderr
    end
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

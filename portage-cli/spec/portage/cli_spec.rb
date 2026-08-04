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

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

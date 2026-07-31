require "spec_helper"
require "webmock/rspec"

RSpec.describe Portage::Ucp::Check do
  describe ".call" do
    it "reports the native manifest when the store already serves /.well-known/ucp" do
      stub_request(:get, "https://shop.example/.well-known/ucp")
        .to_return(status: 200, body: { ucp_version: "2026-04-08", capabilities: [] }.to_json)

      report = described_class.call("shop.example")

      expect(report[:native_ucp]).to eq("ucp_version" => "2026-04-08", "capabilities" => [])
      expect(report).not_to have_key(:platform)
    end

    it "defaults to https when the url has no scheme" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html></html>")

      described_class.call("shop.example")

      expect(a_request(:get, "https://shop.example/.well-known/ucp")).to have_been_made
    end

    it "detects the platform from the homepage when there is no native manifest" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: "<script src=\"https://cdn.shopify.com/s/files/1/foo.js\"></script>")

      report = described_class.call("shop.example")

      expect(report[:platform]).to eq("Shopify")
      expect(report[:recommended_gem]).to eq("portage-ucp-shopify")
    end

    it "skips the live probe when the adapter's required env vars are absent" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)
      stub_request(:get, "https://shop.example/")
        .to_return(status: 200, body: "<script src=\"https://cdn.shopify.com/s/files/1/foo.js\"></script>")

      report = described_class.call("shop.example")

      expect(report[:live_probe][:status]).to eq("skipped")
      expect(report[:live_probe][:reason]).to include("SHOPIFY_SHOP_DOMAIN")
    end

    it "reports no platform match when nothing recognizable is found" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)
      stub_request(:get, "https://shop.example/").to_return(status: 200, body: "<html>hello</html>")

      report = described_class.call("shop.example")

      expect(report[:platform]).to be_nil
      expect(report).not_to have_key(:live_probe)
    end
  end
end

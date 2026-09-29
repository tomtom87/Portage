require "spec_helper"

RSpec.describe Portage::Cli::ProductPage do
  def page(url, store: "https://shop.example") = described_class.new(url: url, store: store)

  describe "#refusal (the host rule)" do
    it "allows an http(s) page on the store's own host, www. or not, any case" do
      expect(page("https://shop.example/products/cold").refusal).to be_nil
      expect(page("http://WWW.Shop.Example/p/1").refusal).to be_nil
      expect(page("https://shop.example/p/1", store: "www.shop.example").refusal).to be_nil
      expect(page("https://www.shop.example/p/1", store: "shop.example").refusal).to be_nil
    end

    it "refuses other hosts, including other subdomains and look-alikes" do
      %w[https://evil.example/p https://cdn.shop.example/p https://shop.example.evil.test/p
         https://shop.example@evil.test/p].each do |url|
        expect(page(url).refusal).to be_a(String), url
      end
    end

    it "refuses a non-http(s) url, credentials in the url, and a missing one" do
      expect(page("javascript:alert(1)").refusal).to include("Not an http(s) URL")
      expect(page("file:///etc/passwd").refusal).to include("Not an http(s) URL")
      expect(page("https://user:pw@shop.example/p").refusal).to include("credentials")
      expect(page(nil).refusal).to include("No product page")
    end
  end

  describe "#open" do
    it "opens an allowed page through the platform opener, array form" do
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("linux-gnu")
      viewer = page("https://shop.example/products/cold")
      allow(viewer).to receive(:system).with("xdg-open", "https://shop.example/products/cold").and_return(true)

      expect(viewer.open).to include(outcome: "viewed", opened: true)
      expect(viewer).to have_received(:system).with("xdg-open", "https://shop.example/products/cold")
    end

    it "reports view_refused and never shells out for a refused page" do
      viewer = page("https://evil.example/p")
      expect(viewer).not_to receive(:system)

      expect(viewer.open).to include(outcome: "view_refused", url: "https://evil.example/p")
    end

    it "still reports viewed (opened: false, with the url) when no browser could be opened" do
      viewer = page("https://shop.example/p")
      allow(viewer).to receive(:system).and_return(false)

      expect(viewer.open).to include(outcome: "viewed", opened: false, message: include("https://shop.example/p"))
    end
  end
end

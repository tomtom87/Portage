require "spec_helper"

RSpec.describe Portage::Ucp::Resolver do
  describe ".detect_platform" do
    it "matches a platform whose marker appears in the body" do
      platform = described_class.detect_platform("<script src=\"https://cdn.shopify.com/foo.js\"></script>", {})

      expect(platform.name).to eq("Shopify")
    end

    it "matches a platform whose marker appears in the headers" do
      platform = described_class.detect_platform("", { "x-wix-request-id" => ["abc"] })

      expect(platform.name).to eq("Wix")
    end

    it "returns nil when nothing recognizable is found" do
      expect(described_class.detect_platform("<html>hello</html>", {})).to be_nil
    end
  end

  describe ".env_for" do
    it "reads the platform's env vars from the process environment" do
      shopify = described_class::PLATFORMS.find { |p| p.name == "Shopify" }

      begin
        ENV["SHOPIFY_SHOP_DOMAIN"] = "shop.example"
        env = described_class.env_for(shopify)

        expect(env[:shop_domain]).to eq("shop.example")
        expect(env[:admin_access_token]).to be_nil
      ensure
        ENV.delete("SHOPIFY_SHOP_DOMAIN")
      end
    end
  end

  describe ".missing_env" do
    it "lists the env var names still missing for the platform's required keys" do
      shopify = described_class::PLATFORMS.find { |p| p.name == "Shopify" }

      expect(described_class.missing_env(shopify, { shop_domain: nil })).to eq(["SHOPIFY_SHOP_DOMAIN"])
    end

    it "returns an empty array once all required keys are present" do
      shopify = described_class::PLATFORMS.find { |p| p.name == "Shopify" }

      expect(described_class.missing_env(shopify, { shop_domain: "shop.example" })).to eq([])
    end
  end

  describe ".build_adapter" do
    it "raises LoadError when the adapter gem isn't installed" do
      shopify = described_class::PLATFORMS.find { |p| p.name == "Shopify" }
      env = { shop_domain: "shop.example", admin_access_token: nil, storefront_access_token: nil }

      expect { described_class.build_adapter(shopify, env) }.to raise_error(LoadError)
    end
  end

  describe "WooCommerce platform" do
    let(:woocommerce) { described_class::PLATFORMS.find { |p| p.name == "WooCommerce" } }

    it "reads WOOCOMMERCE_PAYMENT_METHOD as a completion-only, non-required env var" do
      expect(woocommerce.env[:payment_method]).to eq("WOOCOMMERCE_PAYMENT_METHOD")
      expect(woocommerce.required).not_to include(:payment_method)
    end

    it "threads payment_method through to Adapter.new" do
      namespace = Class.new
      namespace.const_set(:Adapter, Struct.new(:client, :site_url, :currency, :payment_method, keyword_init: true))
      client = Object.new
      env = { site_url: "https://shop.example", currency: "USD", payment_method: "cod" }

      adapter = woocommerce.build_adapter.call(namespace, client, env)

      expect(adapter.payment_method).to eq("cod")
    end
  end
end

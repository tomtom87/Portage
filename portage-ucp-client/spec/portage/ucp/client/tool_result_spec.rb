require "spec_helper"

RSpec.describe Portage::Ucp::Client::ToolResult do
  describe ".extract" do
    it "returns structuredContent from a symbol-keyed (loopback) response" do
      response = { result: { isError: false, content: [], structuredContent: { "id" => "cart_1" } } }

      expect(described_class.extract(response, symbol_keys: true)).to eq({ "id" => "cart_1" })
    end

    it "returns structuredContent from a string-keyed (wire) response" do
      response = { "result" => { "isError" => false, "content" => [], "structuredContent" => { "id" => "cart_1" } } }

      expect(described_class.extract(response, symbol_keys: false)).to eq({ "id" => "cart_1" })
    end

    it "raises ServerError with the content text when isError is true (symbol-keyed)" do
      response = { result: { isError: true, content: [{ type: "text", text: "no anonymous mutation" }] } }

      expect { described_class.extract(response, symbol_keys: true) }
        .to raise_error(Portage::Ucp::Client::ServerError, "no anonymous mutation")
    end

    it "raises ServerError with the content text when isError is true (string-keyed)" do
      response = { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => "rate limited" }] } }

      expect { described_class.extract(response, symbol_keys: false) }
        .to raise_error(Portage::Ucp::Client::ServerError, "rate limited")
    end
  end
end

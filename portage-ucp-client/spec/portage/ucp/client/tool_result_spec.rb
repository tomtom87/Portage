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

    # The shape a real store answers an out-of-stock create_cart with
    # (Shopify, live 2026-09-22) — the whole error envelope as the text
    # block, not a sentence.
    it "parses a JSON error body onto the raised ServerError's payload" do
      body = JSON.generate(
        "ucp" => { "status" => "error" },
        "messages" => [{ "type" => "error", "code" => "out_of_stock", "content" => "Sold out",
                         "severity" => "unrecoverable" }],
        "continue_url" => "https://shop.example/"
      )
      response = { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => body }] } }

      error = begin
        described_class.extract(response, symbol_keys: false)
      rescue Portage::Ucp::Client::ServerError => e
        e
      end

      expect(error.summary).to eq("Sold out")
      expect(error.continue_url).to eq("https://shop.example/")
      expect(error.server_messages)
        .to eq([{ code: "out_of_stock", content: "Sold out", severity: "unrecoverable" }])
      expect(error.message).to eq(body)
    end

    it "leaves payload nil and falls back to the raw text when the body isn't JSON" do
      response = { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => "rate limited" }] } }

      error = begin
        described_class.extract(response, symbol_keys: false)
      rescue Portage::Ucp::Client::ServerError => e
        e
      end

      expect(error.payload).to be_nil
      expect(error.summary).to eq("rate limited")
      expect(error.continue_url).to be_nil
      expect(error.server_messages).to eq([])
    end
  end
end

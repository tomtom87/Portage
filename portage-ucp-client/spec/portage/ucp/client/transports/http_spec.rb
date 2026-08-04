require "spec_helper"

RSpec.describe Portage::Ucp::Client::Transports::Http do
  let(:mcp_transport) { instance_double(MCP::Client::HTTP) }
  let(:mcp_client) { instance_double(MCP::Client) }

  before do
    allow(MCP::Client::HTTP).to receive(:new).with(url: "https://shop.example/mcp", headers: {})
                                             .and_return(mcp_transport)
    allow(MCP::Client).to receive(:new).with(transport: mcp_transport).and_return(mcp_client)
    allow(mcp_client).to receive(:connect)
  end

  it "connects the underlying MCP::Client eagerly" do
    expect(mcp_client).to receive(:connect)

    described_class.new(url: "https://shop.example/mcp")
  end

  it "delegates call_tool and normalizes the string-keyed response" do
    allow(mcp_client).to receive(:call_tool).with(name: "search_catalog", arguments: { query: "x", limit: 1 })
                                            .and_return({ "result" => { "isError" => false, "content" => [],
                                                                        "structuredContent" => [] } })

    result = described_class.new(url: "https://shop.example/mcp")
                            .call_tool(name: "search_catalog", arguments: { query: "x", limit: 1 })

    expect(result).to eq([])
  end

  it "raises ServerError when the response reports isError" do
    allow(mcp_client).to receive(:call_tool).and_return(
      { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => "boom" }] } }
    )

    expect { described_class.new(url: "https://shop.example/mcp").call_tool(name: "x", arguments: {}) }
      .to raise_error(Portage::Ucp::Client::ServerError, "boom")
  end
end

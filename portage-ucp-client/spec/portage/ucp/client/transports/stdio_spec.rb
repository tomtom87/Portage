require "spec_helper"

RSpec.describe Portage::Ucp::Client::Transports::Stdio do
  let(:mcp_transport) { instance_double(MCP::Client::Stdio) }
  let(:mcp_client) { instance_double(MCP::Client) }

  before do
    allow(MCP::Client::Stdio).to receive(:new).with(command: "portage-ucp-server", args: [], env: nil)
                                              .and_return(mcp_transport)
    allow(MCP::Client).to receive(:new).with(transport: mcp_transport).and_return(mcp_client)
    allow(mcp_client).to receive(:connect)
  end

  it "connects the underlying MCP::Client eagerly" do
    expect(mcp_client).to receive(:connect)

    described_class.new(command: "portage-ucp-server")
  end

  it "delegates call_tool and normalizes the string-keyed response" do
    allow(mcp_client).to receive(:call_tool).with(name: "get_order", arguments: { order_id: "o1" })
                                            .and_return({ "result" => { "isError" => false, "content" => [],
                                                                        "structuredContent" => { "id" => "o1" } } })

    result = described_class.new(command: "portage-ucp-server").call_tool(name: "get_order",
                                                                          arguments: { order_id: "o1" })

    expect(result).to eq({ "id" => "o1" })
  end
end

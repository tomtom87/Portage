require "spec_helper"
require "open3"
require "json"
require "rbconfig"
require "portage/cli/mcp/server"

RSpec.describe Portage::Cli::Mcp::Server do
  let(:gem_root) { File.expand_path("../../../..", __dir__) }

  it "builds an MCP server named portage with the flow in its instructions" do
    server = described_class.build

    expect(server.name).to eq("portage")
    expect(described_class::INSTRUCTIONS).to include("quote_purchase").and include("list_orders")
      .and include("untrusted")
      .and include("approve_quote").and include("buy_quote").and include("hand_off").and include("reconcile_orders")
      .and include("own terminal")
  end

  it "rejects `portage mcp` with extra arguments" do
    expect { expect(Portage::Cli.run(%w[mcp --yes])).to eq(1) }.to output(/usage: portage/).to_stderr
  end

  # The real `portage mcp`, like portage-ucp-shopify's exe_spec: an
  # initialize + tools/list + tools/call handshake over stdio, stdin then
  # closed. HOME and the .env file point into a tmp dir, never the real ~.
  it "answers initialize, tools/list and tools/call over stdio" do
    Dir.mktmpdir do |home|
      env = { "HOME" => home, "PORTAGE_ENV_FILE" => File.join(home, ".env"), "LANG" => "en_US.UTF-8",
              "LC_ALL" => "en_US.UTF-8" }
      messages = [
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
        { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_orders", arguments: {} } }
      ]
      stdin_data = "#{messages.map { |m| JSON.generate(m) }.join("\n")}\n"

      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(gem_root, "lib"),
                                              File.join(gem_root, "exe", "portage"), "mcp",
                                              stdin_data: stdin_data, chdir: home)

      expect(status).to be_success, "stderr:\n#{stderr}"
      responses = stdout.each_line.map { |line| JSON.parse(line) }.to_h { |r| [r["id"], r] }
      expect(responses.dig(1, "result", "serverInfo", "name")).to eq("portage")
      expect(responses.dig(2, "result", "tools").map { |t| t["name"] })
        .to contain_exactly(*Portage::Cli::Mcp::Tools::TOOLS.keys)
      expect(responses.dig(3, "result"))
        .to include("isError" => false, "content" => [{ "type" => "text", "text" => "[]" }])
    end
  end
end

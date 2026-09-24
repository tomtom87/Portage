require "spec_helper"
require "open3"
require "json"

RSpec.describe "exe/portage-ucp-bigcommerce" do
  let(:gem_root) { File.expand_path("../../../..", __dir__) }
  let(:exe_path) { File.join(gem_root, "exe", "portage-ucp-bigcommerce") }
  let(:base_env) do
    {
      "BIGCOMMERCE_STORE_HASH" => "abc123",
      "BIGCOMMERCE_CLIENT_ID" => "client-id",
      "BIGCOMMERCE_ACCESS_TOKEN" => "access-tok",
      "BIGCOMMERCE_SITE_URL" => "https://example.test"
    }
  end

  # The exe hands its built server to `StdioTransport#open`, which reads
  # newline-delimited JSON-RPC frames from $stdin until EOF, so a real
  # initialize + tools/list handshake piped over stdin (with stdin then
  # closed) is enough to prove the exe actually starts an MCP server and
  # answers requests, without needing a real BigCommerce store.
  def run_exe(env, stdin_data:)
    Bundler.with_original_env do
      Open3.capture3(base_env.merge(env), "bundle", "exec", "ruby", exe_path, stdin_data: stdin_data,
                                                                              chdir: gem_root)
    end
  end

  it "answers a real MCP initialize + tools/list handshake over stdio" do
    initialize_request = {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {},
                clientInfo: { name: "exe_spec", version: "1.0" } }
    }
    initialized_notification = { jsonrpc: "2.0", method: "notifications/initialized" }
    tools_list_request = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }

    stdin_data = [initialize_request, initialized_notification, tools_list_request]
                 .map { |message| JSON.generate(message) }.join("\n") << "\n"

    stdout, stderr, status = run_exe({}, stdin_data: stdin_data)

    expect(status).to be_success, "expected a clean exit, got stderr:\n#{stderr}"

    responses = stdout.each_line.map { |line| JSON.parse(line) }
    tools_list_response = responses.find { |response| response["id"] == 2 }

    expect(tools_list_response).not_to be_nil, "expected a tools/list response, got stdout:\n#{stdout}"
    expect(tools_list_response["error"]).to be_nil
    tools = tools_list_response.dig("result", "tools")
    expect(tools).to be_an(Array)
    expect(tools).not_to be_empty
  end

  it "raises a clear error when a required env var is missing" do
    _stdout, stderr, status = run_exe({ "BIGCOMMERCE_STORE_HASH" => nil }, stdin_data: "")

    expect(status).not_to be_success
    expect(stderr).to match(/BIGCOMMERCE_STORE_HASH/)
  end
end

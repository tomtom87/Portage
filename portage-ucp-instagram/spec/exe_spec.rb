require "spec_helper"
require "open3"
require "json"

RSpec.describe "exe/portage-ucp-instagram" do
  let(:gem_root) { File.expand_path("..", __dir__) }
  let(:exe_path) { File.join(gem_root, "exe", "portage-ucp-instagram") }
  let(:base_env) do
    { "INSTAGRAM_ACCESS_TOKEN" => "acc-tok", "INSTAGRAM_CATALOG_ID" => "catalog_1" }
  end

  # The exe's `StdioTransport#open` reads newline-delimited JSON-RPC frames
  # from $stdin until EOF, so piping a real initialize + tools/list handshake
  # in and closing stdin is enough to exercise the whole exe — requires,
  # Client/Adapter construction, Server.build, and the transport itself —
  # against its actual stdout responses, without needing a real Meta account
  # or leaving the process blocked on the stdio loop.
  def run_exe(env, input)
    Bundler.with_original_env do
      Open3.capture3(base_env.merge(env), "bundle", "exec", "ruby", exe_path, stdin_data: input,
                                                                              chdir: gem_root)
    end
  end

  def frame(hash)
    "#{JSON.generate(hash)}\n"
  end

  it "loads, negotiates initialize, and lists tools with only its required env vars" do
    input = frame(jsonrpc: "2.0", id: 1, method: "initialize",
                  params: { protocolVersion: "2025-11-25", capabilities: {},
                            clientInfo: { name: "test-client", version: "1.0" } }) +
            frame(jsonrpc: "2.0", id: 2, method: "tools/list")

    stdout, stderr, status = run_exe({}, input)

    expect(status).to be_success, "expected a clean exit, got stderr:\n#{stderr}"

    responses = stdout.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
    initialize_response = responses.find { |r| r[:id] == 1 }
    tools_list_response = responses.find { |r| r[:id] == 2 }

    expect(initialize_response.dig(:result, :serverInfo, :name)).to eq("portage-ucp")

    tool_names = tools_list_response.dig(:result, :tools).map { |t| t[:name] }
    expect(tool_names).to include("search_catalog", "get_product")
  end

  it "raises a clear error when a required env var is missing" do
    _stdout, stderr, status = run_exe({ "INSTAGRAM_CATALOG_ID" => nil }, "")

    expect(status).not_to be_success
    expect(stderr).to match(/INSTAGRAM_CATALOG_ID/)
  end

  it "loads examples/portage_ucp.rb via PORTAGE_UCP_CONFIG" do
    example_path = File.join(gem_root, "examples", "portage_ucp.rb")

    _stdout, stderr, status = run_exe(
      { "PORTAGE_UCP_CONFIG" => example_path, "PORTAGE_UCP_BEARER_TOKEN" => "secret" }, ""
    )

    expect(status).to be_success, "expected a clean exit, got stderr:\n#{stderr}"
  end
end

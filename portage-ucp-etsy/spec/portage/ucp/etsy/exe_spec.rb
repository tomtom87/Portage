require "spec_helper"
require "open3"

RSpec.describe "exe/portage-ucp-etsy" do
  let(:gem_root) { File.expand_path("../../../..", __dir__) }
  let(:exe_path) { File.join(gem_root, "exe", "portage-ucp-etsy") }
  let(:base_env) do
    { "ETSY_ACCESS_TOKEN" => "acc-tok", "ETSY_API_KEY" => "keystring", "ETSY_SHOP_ID" => "42" }
  end

  # The exe's `Server.build(...).start` reads newline-delimited JSON-RPC
  # frames from $stdin until EOF (see mcp's StdioTransport#open), so handing
  # it a closed stdin is enough to load the whole exe — requires, client/
  # adapter construction, server build — and have it exit cleanly on its own,
  # without needing a real Etsy account or a JSON-RPC client on the other end.
  def run_exe(env)
    Bundler.with_original_env do
      Open3.capture3(base_env.merge(env), "bundle", "exec", "ruby", exe_path, stdin_data: "",
                                                                              chdir: gem_root)
    end
  end

  it "loads and starts cleanly with only its required env vars" do
    _stdout, stderr, status = run_exe({})

    expect(status).to be_success, "expected a clean exit, got stderr:\n#{stderr}"
  end

  it "raises a clear error when a required env var is missing" do
    _stdout, stderr, status = run_exe({ "ETSY_SHOP_ID" => nil })

    expect(status).not_to be_success
    expect(stderr).to match(/ETSY_SHOP_ID/)
  end

  it "loads examples/portage_ucp.rb via PORTAGE_UCP_CONFIG" do
    example_path = File.join(gem_root, "examples", "portage_ucp.rb")

    _stdout, stderr, status = run_exe(
      "PORTAGE_UCP_CONFIG" => example_path,
      "PORTAGE_UCP_BEARER_TOKEN" => "secret"
    )

    expect(status).to be_success, "expected a clean exit, got stderr:\n#{stderr}"
  end
end

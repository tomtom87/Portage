require "spec_helper"
require "open3"

# Loads the exe script in-process (rather than shelling out, which would
# block forever on the MCP server's stdio loop) with Server.build/#start
# doubled out — this only confirms the exe wires ENV into a real Client +
# Adapter and hands it to the server, the same "does this script actually
# work" gap a shelled-out invocation would otherwise leave uncovered.
RSpec.describe "exe/portage-ucp-instagram" do
  let(:exe_path) { File.expand_path("../exe/portage-ucp-instagram", __dir__) }

  around do |example|
    original = ENV.to_hash
    example.run
  ensure
    ENV.replace(original)
  end

  it "parses as valid Ruby" do
    _out, err, status = Open3.capture3("ruby", "-c", exe_path)
    expect(status).to be_success, err
  end

  it "builds a Client + Adapter from ENV and starts the MCP server" do
    ENV["INSTAGRAM_ACCESS_TOKEN"] = "acc-tok"
    ENV["INSTAGRAM_CATALOG_ID"] = "catalog_1"
    ENV.delete("PORTAGE_UCP_CONFIG")

    # A plain double, not instance_double: .build's real return value is
    # ::MCP::Server (the `mcp` gem), not Portage::Ucp::Mcp::Server itself
    # (see Portage::Ucp::Mcp::Server.build) — all this test cares about is
    # that the exe hands its result to #start, not the real gem's interface.
    server = double("mcp_server", start: nil)
    allow(Portage::Ucp::Mcp::Server).to receive(:build).and_return(server)

    load exe_path

    expect(Portage::Ucp::Mcp::Server).to have_received(:build) do |adapter:|
      expect(adapter).to be_a(Portage::Ucp::Instagram::Adapter)
    end
    expect(server).to have_received(:start)
  end
end

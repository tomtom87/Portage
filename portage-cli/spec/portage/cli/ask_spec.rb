require "spec_helper"

# `portage ask` (docs/plans/ucp-ask.md Phase 2), through Cli.run with only the
# UCP session faked.
RSpec.describe "portage ask" do
  let(:advertised) { true }
  let(:wire) do
    { "answer" => { "plain" => "Lead time is 6 weeks." },
      "links" => [{ "title" => "Terms", "url" => "https://shop.example/terms" }],
      "conversation" => { "id" => "conv_1" },
      "messages" => [{ "type" => "info", "code" => "operation_not_performed", "content" => "Nothing was added." }] }
  end
  let(:session) { instance_double(Portage::Ucp::Client::Session, ask: wire) }

  before do
    allow(session).to receive(:advertises?).with("dev.ucp.common.ask") { advertised }
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
    allow(Portage::Cli::AgentProfileUrl).to receive(:resolve).and_return("https://agent.example/profile.json")
  end

  def run(*argv)
    out = StringIO.new
    $stdout = out
    code = Portage::Cli.run(["ask", *argv])
    [code, out.string]
  ensure
    $stdout = STDOUT
  end

  it "prints the answer, its links, store messages and how to continue, and exits 0" do
    code, out = run("https://shop.example/x", "lead time?")

    expect(code).to eq(0)
    expect(out).to include("Lead time is 6 weeks.", "Terms - https://shop.example/terms",
                           "[info] operation_not_performed: Nothing was added.", "conversation: conv_1",
                           'portage ask https://shop.example "..." --conversation conv_1')
    expect(session).to have_received(:ask).with(query: "lead time?", ids: nil, conversation: nil,
                                                meta: { agent_profile: "https://agent.example/profile.json" })
  end

  it "prints the report as JSON" do
    code, out = run("https://shop.example", "lead time?", "--json")

    expect(code).to eq(0)
    expect(JSON.parse(out)).to include("url" => "https://shop.example", "query" => "lead time?", "ids" => [],
                                       "answer" => { "plain" => "Lead time is 6 weeks." },
                                       "conversation" => { "id" => "conv_1" }, "outcome" => "answered")
    expect(JSON.parse(out).keys).to include("links", "messages")
  end

  it "maps repeated --product-id to ids and --conversation to conversation.id" do
    run("shop.example", "price?", "--product-id", "a", "--product-id", "b", "--conversation", "conv_0")

    expect(session).to have_received(:ask).with(hash_including(ids: %w[a b], conversation: { id: "conv_0" }))
  end

  context "when the store doesn't advertise ask" do
    let(:advertised) { false }

    it "makes no ask request and reports not_offered" do
      code, out = run("https://shop.example", "lead time?", "--json")

      expect(code).to eq(1)
      expect(JSON.parse(out)).to include("outcome" => "not_offered", "answer" => nil)
      expect(session).not_to have_received(:ask)
    end
  end

  it "short-circuits a hand-off-only host without fetching it" do
    code, out = run("https://www.amazon.com", "lead time?", "--json")

    expect(code).to eq(1)
    expect(JSON.parse(out)).to include("outcome" => "handoff_only")
    expect(Portage::Ucp::Client).not_to have_received(:discover)
  end

  it "reports a store error with the store's code and text, and exits 1" do
    payload = { "messages" => [{ "type" => "error", "code" => "capabilities_incompatible",
                                 "content" => "No shared version of the requested capability." }] }
    allow(session).to receive(:ask)
      .and_raise(Portage::Ucp::Client::ServerError.new("HTTP 400: No shared version of the requested capability.",
                                                       payload: payload))

    code, out = run("https://shop.example", "lead time?")

    expect(code).to eq(1)
    expect(out).to include("capabilities_incompatible", "No shared version of the requested capability.")
    expect(JSON.parse(run("https://shop.example", "q", "--json").last)).to include("outcome" => "error",
                                                                                   "messages" => payload["messages"])
  end

  it "reports an error envelope sent with HTTP 200 (ucp.status error, no answer) as an error, as AirShelf does" do
    messages = [{ "type" => "error", "code" => "capabilities_incompatible",
                  "content" => "No shared version of the requested capability.", "severity" => "unrecoverable" }]
    allow(session).to receive(:ask).and_return({ "ucp" => { "status" => "error" }, "messages" => messages })

    code, out = run("https://shop.example", "lead time?")

    expect(code).to eq(1)
    expect(out).to include("No shared version of the requested capability. (capabilities_incompatible)")
    expect(JSON.parse(run("https://shop.example", "q", "--json").last)).to include("outcome" => "error",
                                                                                   "messages" => messages)
  end

  it "reports a store that doesn't speak UCP as an error" do
    allow(Portage::Ucp::Client).to receive(:discover).and_raise(Portage::Ucp::Client::DiscoveryError)

    expect(run("https://shop.example", "q", "--json").last).to include('"outcome": "error"')
  end

  it "prints usage and exits 1 without a question or with a bad url" do
    expect { expect(Portage::Cli.run(["ask", "https://shop.example"])).to eq(1) }.to output(/usage: portage/).to_stderr
    expect { expect(Portage::Cli.run(["ask", "ftp://shop.example", "q"])).to eq(1) }
      .to output(/usage: portage/).to_stderr
  end
end

require "spec_helper"
require "portage/ucp/webmcp"

RSpec.describe Portage::Cli::BrowserProfile::Bridge do
  let(:socket) { instance_double(Portage::Cli::BrowserProfile::CdpSocket) }
  let(:allowlist) { Portage::Cli::BrowserProfile::Allowlist.new(hosts: ["store.example"]) }
  let(:bridge) { described_class.new(socket: socket, allowlist: allowlist) }

  # Every Bridge call probes `window.location.href` first (the allowlist
  # check) before doing the real work — stubbed by that exact literal
  # expression (never by guessing at consumer.js/autofill.js's own
  # source), so tests don't depend on those assets' file contents at all.
  def stub_location(url)
    allow(socket).to receive(:call)
      .with("Runtime.evaluate", hash_including("expression" => "Promise.resolve(window.location.href)"))
      .and_return("result" => { "value" => url })
  end

  # consumer.js/autofill.js's own envelope contract — {"ok": true,
  # "value": ...} — is what ScriptEvaluator#unwrap actually expects back
  # from the resolved page promise (see Bridges::ScriptEvaluator#unwrap).
  def stub_work(value)
    allow(socket).to receive(:call)
      .with("Runtime.evaluate", hash_including("expression" => satisfy { |e| !e.include?("window.location.href") }))
      .and_return("result" => { "value" => { "ok" => true, "value" => value }.to_json })
  end

  it "is never headless — a shopper can always see and pay in it" do
    expect(bridge.headless?).to be false
  end

  it "reads the page's location by evaluating window.location.href" do
    stub_location("https://store.example/cart")

    expect(bridge.location).to eq("https://store.example/cart")
  end

  describe "list_tools/execute_tool (via the delegated ScriptEvaluator)" do
    it "runs a consumer.js list call and returns its tools when on an allowed host" do
      stub_location("https://store.example/")
      stub_work([{ "name" => "search_catalog" }])

      expect(bridge.list_tools).to eq([{ "name" => "search_catalog" }])
    end

    it "stops the run when the page has navigated off the allowed domain" do
      stub_location("https://evil.example/")

      # Bridges::ScriptEvaluator#evaluate wraps whatever its injected
      # evaluate: callable raises into its own BridgeError (see
      # ScriptEvaluator#evaluate's rescue StandardError) — so the
      # allowlist violation still surfaces, just re-typed; the next
      # example proves the underlying DomainNotAllowedError is really
      # what tripped it.
      expect { bridge.list_tools }
        .to raise_error(Portage::Ucp::WebMcp::BridgeError, /outside the allowed domains/)
    end

    it "raises Portage::Cli::BrowserProfile::DomainNotAllowedError from #evaluate itself" do
      stub_location("https://evil.example/")

      expect { bridge.send(:evaluate, "1") }
        .to raise_error(Portage::Cli::BrowserProfile::DomainNotAllowedError, /evil\.example/)
    end
  end

  describe "#navigate" do
    it "permits the target host, enables Page domain once, and navigates" do
      expect(socket).to receive(:call).with("Page.enable", {}).once.and_return({})
      expect(socket).to receive(:call).with("Page.navigate", "url" => "https://checkout.example/pay")

      expect(allowlist.allowed?("checkout.example")).to be false
      bridge.navigate("https://checkout.example/pay")
      expect(allowlist.allowed?("checkout.example")).to be true
    end

    it "only enables the Page domain on the first navigate" do
      allow(socket).to receive(:call).with("Page.navigate", anything)
      expect(socket).to receive(:call).with("Page.enable", {}).once.and_return({})

      bridge.navigate("https://store.example/a")
      bridge.navigate("https://store.example/b")
    end
  end

  it "raises a BridgeError when the page's own script threw" do
    stub_location("https://store.example/")
    allow(socket).to receive(:call)
      .with("Runtime.evaluate", hash_including("expression" => satisfy { |e| !e.include?("window.location.href") }))
      .and_return("exceptionDetails" => { "text" => "boom" })

    expect { bridge.execute_tool("search_catalog", {}) }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /boom/)
  end

  it "never returns :needs_headed_browser from Autofill — this bridge is always headed" do
    stub_location("https://store.example/")
    stub_work("filled" => [], "unmatched" => [], "rate" => [])

    result = Portage::Ucp::WebMcp::Autofill.call(bridge: bridge, fields: { "email" => "a@example.com" })

    expect(result.outcome).not_to eq(:needs_headed_browser)
  end
end

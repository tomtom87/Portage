require "spec_helper"

RSpec.describe Portage::Cli::BrowserProfile::Cdp do
  let(:port) { 9223 }

  describe ".version" do
    it "returns the parsed /json/version body when the profile answers" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/version")
        .to_return(status: 200, body: { "Browser" => "Chrome/999" }.to_json)

      expect(described_class.version(port: port)).to eq("Browser" => "Chrome/999")
    end

    it "returns nil when nothing is listening (connection refused)" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/version").to_raise(Errno::ECONNREFUSED)

      expect(described_class.version(port: port)).to be_nil
    end

    it "returns nil on a non-2xx response" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/version").to_return(status: 500)

      expect(described_class.version(port: port)).to be_nil
    end
  end

  describe ".list" do
    it "returns the tab list as an array" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/list")
        .to_return(status: 200, body: [{ "id" => "1", "type" => "page" }].to_json)

      expect(described_class.list(port: port)).to eq([{ "id" => "1", "type" => "page" }])
    end

    it "returns an empty array rather than nil when the endpoint doesn't answer" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/list").to_raise(Errno::ECONNREFUSED)

      expect(described_class.list(port: port)).to eq([])
    end
  end

  describe ".new_tab" do
    it "PUTs to /json/new with the URL and returns the new target descriptor" do
      stub = stub_request(:put, "http://127.0.0.1:#{port}/json/new?https%3A%2F%2Fexample.com%2Fcart")
             .to_return(status: 200, body: { "id" => "2", "webSocketDebuggerUrl" => "ws://x" }.to_json)

      result = described_class.new_tab(port: port, url: "https://example.com/cart")

      expect(result).to eq("id" => "2", "webSocketDebuggerUrl" => "ws://x")
      expect(stub).to have_been_requested
    end
  end

  describe ".close_tab" do
    it "returns true on a 200 even though the body is plain text, not JSON" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/close/2").to_return(status: 200, body: "Target is closing")

      expect(described_class.close_tab(port: port, id: "2")).to be true
    end

    it "returns false when the profile isn't reachable" do
      stub_request(:get, "http://127.0.0.1:#{port}/json/close/2").to_raise(Errno::ECONNREFUSED)

      expect(described_class.close_tab(port: port, id: "2")).to be false
    end
  end
end

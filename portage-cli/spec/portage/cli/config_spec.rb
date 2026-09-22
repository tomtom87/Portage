require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Config do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "config.json")
      example.run
    end
  end

  it "returns nil for an unset key when no file exists" do
    expect(described_class.load(path: @path).get("auto_open_checkout")).to be_nil
  end

  it "persists a set value across loads" do
    described_class.load(path: @path).set("auto_open_checkout", true)

    expect(described_class.load(path: @path).get("auto_open_checkout")).to be true
  end

  it "only touches the key it's given, leaving others intact" do
    config = described_class.load(path: @path)
    config.set("auto_open_checkout", true)
    config.set("notify_webhook_url", "https://hooks.example/x")

    reloaded = described_class.load(path: @path)
    expect(reloaded.get("auto_open_checkout")).to be true
    expect(reloaded.get("notify_webhook_url")).to eq("https://hooks.example/x")
  end
end

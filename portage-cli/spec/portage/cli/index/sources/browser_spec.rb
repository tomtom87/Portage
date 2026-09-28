require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::Sources::Browser do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "browser-import.json")
      example.run
    end
  end

  let(:source) { described_class.new(path: @path) }

  it "yields nothing when Phase 3's output file doesn't exist yet" do
    expect(source.candidates).to eq([])
  end

  it "reads entries from the file when Phase 3 has written one" do
    File.write(@path, JSON.generate(entries: [{ "origin" => "https://shop.example",
                                                "url" => "https://shop.example/products/x", "title" => "Thing" }]))

    expect(source.candidates).to eq([{ origin: "https://shop.example", url: "https://shop.example/products/x",
                                       title: "Thing", brand: nil, gtin: nil }])
  end

  it "tolerates a corrupt file rather than raising" do
    File.write(@path, "not json")

    expect(source.candidates).to eq([])
  end

  it "never reads a browser's cookie/credential store — only its own JSON output path" do
    expect(source.source_path).to eq(@path)
  end
end

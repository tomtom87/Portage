require "spec_helper"

RSpec.describe Portage::Cli::BrowserImport::PlistXml do
  let(:xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Children</key>
        <array>
          <dict>
            <key>Title</key><string>Shops &amp; Gear</string>
            <key>Children</key>
            <array>
              <dict>
                <key>URLString</key><string>https://shop.example/products/boots?a=1&amp;b=2</string>
                <key>URIDictionary</key><dict><key>title</key><string>Caf&#233; Boots</string></dict>
                <key>Added</key><date>2026-01-01T00:00:00Z</date>
                <key>Sync</key><data>AAEC</data>
              </dict>
            </array>
          </dict>
          <dict/>
        </array>
        <key>Empty</key><string/>
        <key>Flag</key><true/>
        <key>Count</key><integer>3</integer>
      </dict>
      </plist>
    XML
  end

  it "parses dicts, arrays, strings, entities and the scalar types Safari uses" do
    parsed = described_class.parse(xml)

    folder = parsed["Children"].first
    leaf = folder["Children"].first
    expect(folder["Title"]).to eq("Shops & Gear")
    expect(leaf["URLString"]).to eq("https://shop.example/products/boots?a=1&b=2")
    expect(leaf["URIDictionary"]["title"]).to eq("Café Boots")
    expect(leaf["Added"]).to eq("2026-01-01T00:00:00Z")
    expect(parsed["Children"].last).to eq({})
    expect(parsed).to include("Empty" => "", "Flag" => true, "Count" => "3")
  end

  it "decodes all five named entities and decimal and hex character references" do
    parsed = described_class.parse("<plist><string>&lt;&gt;&amp;&quot;&apos; &#233; &#xE9; &#x1F600;</string></plist>")
    expect(parsed).to eq("<>&\"' é é \u{1F600}")
  end

  it "raises ParseError on something that isn't an XML plist" do
    expect { described_class.parse("bplist00garbage") }.to raise_error(described_class::ParseError)
    expect { described_class.parse("<plist><dict><key>a</key>") }.to raise_error(described_class::ParseError)
  end
end

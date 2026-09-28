require "spec_helper"

RSpec.describe Portage::Cli::BrowserImport::Filter do
  it "lets an ordinary shop domain through to a probe" do
    expect(described_class.skip_reason("allbirds.com")).to be_nil
    expect(described_class.skip_reason("shop.example.co.uk")).to be_nil
  end

  it "skips SearchBackends::NON_STORE_HOSTS and other obvious non-shops" do
    expect(described_class.skip_reason("en.wikipedia.org")).to eq(:non_store)
    expect(described_class.skip_reason("www.youtube.com")).to eq(:non_store)
    expect(described_class.skip_reason("github.com")).to eq(:non_store)
    expect(described_class.skip_reason("docs.google.com")).to eq(:non_store)
  end

  it "skips webmail" do
    expect(described_class.skip_reason("mail.google.com")).to eq(:webmail)
    expect(described_class.skip_reason("outlook.live.com")).to eq(:webmail)
    expect(described_class.skip_reason("webmail.anything.example")).to eq(:webmail)
  end

  it "skips banks and payment hosts, including the long tail by name" do
    expect(described_class.skip_reason("www.paypal.com")).to eq(:bank)
    expect(described_class.skip_reason("online.lloydsbank.co.uk")).to eq(:bank)
    expect(described_class.skip_reason("myfirstcreditunion.org")).to eq(:bank)
  end

  it "skips localhost, intranet and bare-IP hosts" do
    %w[localhost 127.0.0.1 192.168.1.10 [::1] intranet wiki.corp jenkins.internal nas.local
       router.home.arpa app.test].each do |host|
      expect(described_class.skip_reason(host)).to eq(:local), host
    end
  end
end

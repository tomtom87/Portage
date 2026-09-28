require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::WebmcpSweep do
  it "skips cleanly with no bridge configured" do
    expect(described_class.new.candidates).to eq([])
  end

  it "still names itself so `portage index sources` can list it" do
    source = described_class.new
    expect(source.name).to eq("webmcp_sweep")
    expect(source.description).to be_a(String)
    expect(source.source_path).to be_nil
  end
end

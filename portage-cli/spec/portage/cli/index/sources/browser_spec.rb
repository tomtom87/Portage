require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::Browser do
  let(:source) { described_class.new }

  it "yields nothing — `portage browser import` writes browser entries itself, after approval" do
    expect(source.candidates).to eq([])
    expect(source.candidates(queries: ["boots"])).to eq([])
  end

  it "reads no file of its own, so `index build` can never read browser history by itself" do
    expect(File).not_to receive(:read)
    expect(source.source_path).to be_nil
    source.candidates
  end

  it "points at the import command in its description" do
    expect(source.description).to include("portage browser import")
  end
end

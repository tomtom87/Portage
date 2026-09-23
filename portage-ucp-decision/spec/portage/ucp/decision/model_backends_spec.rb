require "spec_helper"

RSpec.describe Portage::Ucp::Decision::ModelBackends do
  it "resolves jev" do
    expect(described_class.resolve("jev", api_key: "k")).to be_a(Portage::Ucp::Decision::ModelBackends::Jev)
  end

  it "resolves laya" do
    expect(described_class.resolve("laya", command: "echo")).to be_a(Portage::Ucp::Decision::ModelBackends::Laya)
  end

  it "raises UnknownBackendError for an unregistered name" do
    expect { described_class.resolve("gpt5") }.to raise_error(Portage::Ucp::Decision::UnknownBackendError, /gpt5/)
  end
end

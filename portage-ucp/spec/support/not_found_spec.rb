require "spec_helper"

RSpec.describe Portage::Ucp::Support::NotFound do
  read_error = Class.new(StandardError) do
    include Portage::Ucp::Support::ApiError

    private

    def api_label = "ReadTest"
  end

  let(:reader) do
    Class.new do
      include Portage::Ucp::Support::NotFound

      def read(&block) = nil_on_not_found(&block)
    end.new
  end

  it "returns the block's value when nothing raises" do
    expect(reader.read { "product" }).to eq("product")
  end

  it "returns nil for a 404 — an absent resource, not a failure" do
    expect(reader.read { raise read_error.new(404, {}) }).to be_nil
  end

  it "re-raises any other API error" do
    expect { reader.read { raise read_error.new(401, {}) } }.to raise_error(read_error)
  end

  it "re-raises errors that aren't API errors at all" do
    expect { reader.read { raise ArgumentError, "bug" } }.to raise_error(ArgumentError)
  end
end

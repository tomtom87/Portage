require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::WebmcpAutofillConfirm do
  let(:fields) { { "email" => "buyer@example.com", "shipping address-line1" => "1 Main St" } }

  it "refuses when not interactive (no TTY / --json), without ever prompting" do
    output = StringIO.new
    confirm = described_class.new(interactive: false, output: output)

    expect(confirm.call(fields)).to be(false)
    expect(output.string).to eq("")
  end

  it "refuses for empty fields even when interactive — nothing to confirm" do
    confirm = described_class.new(interactive: true, input: StringIO.new("y\n"), output: StringIO.new)

    expect(confirm.call({})).to be(false)
  end

  it "approves on an explicit 'y', printing every field/value first" do
    output = StringIO.new
    confirm = described_class.new(interactive: true, input: StringIO.new("y\n"), output: output)

    expect(confirm.call(fields)).to be(true)
    expect(output.string).to include("email: buyer@example.com", "shipping address-line1: 1 Main St")
  end

  it "refuses on anything but an explicit 'y'" do
    confirm = described_class.new(interactive: true, input: StringIO.new("\n"), output: StringIO.new)

    expect(confirm.call(fields)).to be(false)
  end

  it "refuses on EOF (stdin closed out from under a headless run)" do
    confirm = described_class.new(interactive: true, input: StringIO.new, output: StringIO.new)

    expect(confirm.call(fields)).to be(false)
  end
end

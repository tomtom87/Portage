require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Generate::Adapter do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "scaffolds a gem directory named after the given adapter" do
    path = described_class.new(name: "acme_pay").call

    expect(path).to eq("portage-ucp-acme_pay")
    expect(Dir.exist?(path)).to be true
  end

  it "writes an Adapter subclass with a stub for every Portage::Ucp::Adapter method" do
    described_class.new(name: "acme_pay").call

    body = File.read("portage-ucp-acme_pay/lib/portage/ucp/acme_pay/adapter.rb")
    expect(body).to include("module AcmePay", "class Adapter < Portage::Ucp::Adapter")

    Portage::Ucp::Adapter.instance_methods(false).each do |name|
      next if name.to_s.end_with?("_supported?")

      expect(body).to include("def #{name}(")
    end
  end

  it "writes a gemspec, conformance spec, and version file that all load without error" do
    described_class.new(name: "acme_pay").call

    expect { load "portage-ucp-acme_pay/lib/portage/ucp/acme_pay/version.rb" }.not_to raise_error
    expect(RubyVM::InstructionSequence.compile_file("portage-ucp-acme_pay/portage-ucp-acme_pay.gemspec")).to be_a(
      RubyVM::InstructionSequence
    )
  end

  it "honors a custom --dir" do
    path = described_class.new(name: "acme_pay", dir: "custom-dir").call

    expect(path).to eq("custom-dir")
    expect(Dir.exist?("custom-dir")).to be true
  end
end

require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::Journal::FileStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "journal.jsonl")
      example.run
    end
  end

  def store
    described_class.new(path: @path)
  end

  it "replays appended records, in write order, from a fresh instance" do
    store.append({ "a" => 1 })
    store.append({ "a" => 2 })

    expect(described_class.new(path: @path).each_record.to_a).to eq([{ "a" => 1 }, { "a" => 2 }])
  end

  it "returns an empty enumerator when nothing has been written" do
    expect(store.each_record.to_a).to eq([])
  end

  it "sets 0600 permissions on the file" do
    store.append({ "a" => 1 })

    expect(File.stat(@path).mode & 0o777).to eq(0o600)
  end

  it "skips a torn trailing line instead of raising" do
    store.append({ "a" => 1 })
    File.open(@path, "a") { |f| f.write("{not valid json") }

    expect(store.each_record.to_a).to eq([{ "a" => 1 }])
  end

  it "raises on a torn line that isn't the last one" do
    store.append({ "a" => 1 })
    File.write(@path, "{not valid json\n#{File.read(@path)}")

    expect { store.each_record.to_a }.to raise_error(JSON::ParserError)
  end

  it "never truncates or rewrites earlier lines on a later append" do
    store.append({ "a" => 1 })
    contents_after_first = File.read(@path)
    store.append({ "a" => 2 })

    expect(File.read(@path)).to start_with(contents_after_first)
  end
end

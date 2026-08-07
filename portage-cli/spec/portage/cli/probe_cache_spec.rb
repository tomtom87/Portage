require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::ProbeCache do
  around do |example|
    Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "cache.json") and example.run }
  end

  def cache(now: Time.now) = described_class.new(path: @path, now: now)

  it "returns nil for an origin it has never seen" do
    expect(cache.fetch("https://shop.example")).to be_nil
  end

  it "round-trips a verdict through the file" do
    cache.record("https://shop.example", true)

    expect(cache.fetch("https://shop.example")).to be true
  end

  it "expires hits after six hours" do
    now = Time.now
    cache(now: now).record("https://shop.example", true)

    expect(cache(now: now + described_class::HIT_TTL + 1).fetch("https://shop.example")).to be_nil
  end

  it "holds misses for a full day, since they change least" do
    now = Time.now
    cache(now: now).record("https://shop.example", false)

    expect(cache(now: now + described_class::HIT_TTL + 1).fetch("https://shop.example")).to be false
    expect(cache(now: now + described_class::MISS_TTL + 1).fetch("https://shop.example")).to be_nil
  end

  it "treats a corrupt cache file as an empty one" do
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{not json")

    expect(cache.fetch("https://shop.example")).to be_nil
  end

  it "keeps working when the cache can't be written" do
    allow(File).to receive(:write).and_raise(Errno::EACCES)

    expect(cache.record("https://shop.example", true)).to be true
  end
end

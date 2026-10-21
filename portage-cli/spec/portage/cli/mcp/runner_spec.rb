require "spec_helper"
require "rbconfig"
require "json"
require "portage/cli/mcp/server"

RSpec.describe Portage::Cli::Mcp::Runner do
  # A tiny `ruby -e` child in place of exe/portage; the tool argv follows it.
  def runner(script, **opts)
    described_class.new(command: [RbConfig.ruby, "-e", script], **opts)
  end

  def text(response) = response.content.first[:text]

  it "returns the command's JSON, with the argv passed through untouched by any shell" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "pwned")
      args = ["find", "--query", "$(touch #{marker}); `touch #{marker}` | x", "--json"]
      response = runner("require 'json'; puts JSON.generate(ARGV)").response(args)

      expect(response.error?).to be(false)
      expect(JSON.parse(text(response))).to eq(args)
      expect(File.exist?(marker)).to be(false)
    end
  end

  it "gives the child empty stdin" do
    data, error = runner("require 'json'; puts JSON.generate(STDIN.read)").call([])

    expect([data, error]).to eq(["", nil])
  end

  it "keeps a JSON report from a non-zero exit as the result" do
    data, error = runner('puts %({"offers":[]}); exit 1').call(%w[find])

    expect([data, error]).to eq([{ "offers" => [] }, nil])
  end

  it "reports a non-zero exit without JSON as an error, with stderr" do
    response = runner('warn "boom"; exit 3').response(%w[check])

    expect(response.error?).to be(true)
    expect(text(response)).to include("portage check exited 3").and include("stderr: boom")
  end

  it "reports invalid JSON as an error" do
    response = runner('puts "not json"').response(%w[doctor])

    expect(response.error?).to be(true)
    expect(text(response)).to include("without valid JSON output")
  end

  it "kills a command that runs past the timeout" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = runner("sleep 10", timeout: 0.3).response([])

    expect(response.error?).to be(true)
    expect(text(response)).to include("timed out")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end

  it "kills a command whose output passes the cap" do
    response = runner('loop { $stdout.write("x" * 4096) }', max_bytes: 10_000).response([])

    expect(response.error?).to be(true)
    expect(text(response)).to include("exceeded the 10000-byte cap")
  end

  it "reports an executable that can't start as an error" do
    response = described_class.new(command: ["/nonexistent/portage"]).response([])

    expect(response.error?).to be(true)
    expect(text(response)).to include("could not run portage")
  end

  it "reports each section of a combined run separately" do
    script = 'ARGV.first == "ok" ? puts(%({"a":1})) : exit(2)'
    response = runner(script).sections(good: %w[ok], bad: %w[bad])

    expect(response.error?).to be(false)
    expect(JSON.parse(text(response))).to eq("good" => { "a" => 1 },
                                             "bad" => { "error" => "portage bad exited 2 without valid JSON output" })
  end
end

require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Portage::Cli::SetupWizard::Steps::AgentProfile do
  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  def run(answers, env_path:)
    output = StringIO.new
    with_env("PORTAGE_AGENT_PROFILE" => nil, "PORTAGE_ENV_FILE" => env_path) do
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "does nothing when declined — no file written, nothing generated" do
    output = run("n\n", env_path: File.join(Dir.pwd, ".env"))

    expect(output).to include(Portage::Cli::AgentProfileUrl::DEFAULT)
    expect(File.exist?("agent-profile.json")).to be(false)
  end

  it "generates a profile with default paths, then saves a hosting URL when one is given" do
    env_path = File.join(Dir.pwd, ".env")
    capture_stdout { run("y\n\n\nhttps://example.com/agent-profile.json\n", env_path: env_path) }

    expect(File.exist?("agent-profile.json")).to be(true)
    expect(File.exist?("agent-profile.key.pem")).to be(true)
    expect(Portage::Cli::DotEnv.parse(File.read(env_path)))
      .to eq("PORTAGE_AGENT_PROFILE" => "https://example.com/agent-profile.json")
  end

  it "generates but leaves PORTAGE_AGENT_PROFILE unset when no hosting URL is given" do
    env_path = File.join(Dir.pwd, ".env")
    capture_stdout { run("y\n\n\n\n", env_path: env_path) }

    expect(File.exist?(env_path)).to be(false)
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::SearchKeys do
  around { |example| Dir.mktmpdir { |dir| @env_path = File.join(dir, ".env") and example.run } }

  def unset_search_keys_env = { "BRAVE_SEARCH_API_KEY" => nil, "GOOGLE_CSE_KEY" => nil, "GOOGLE_CSE_CX" => nil }

  def run(answers)
    output = StringIO.new
    with_env(unset_search_keys_env.merge("PORTAGE_ENV_FILE" => @env_path)) do
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "leaves the file untouched when every field is left blank" do
    run("\n\n\n")

    expect(File.exist?(@env_path)).to be(false)
  end

  it "saves whichever keys were typed" do
    run("brave-key\n\n\n")

    expect(Portage::Cli::DotEnv.parse(File.read(@env_path))).to eq("BRAVE_SEARCH_API_KEY" => "brave-key")
  end

  it "never prints either secret key's own value" do
    output = run("brave-key\ngoogle-key\nmy-cx-id\n")

    expect(output).not_to include("brave-key", "google-key")
  end
end

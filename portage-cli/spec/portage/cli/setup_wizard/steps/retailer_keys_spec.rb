require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::RetailerKeys do
  around { |example| Dir.mktmpdir { |dir| @env_path = File.join(dir, ".env") and example.run } }

  def unset_retailer_keys_env
    { "WALMART_AFFILIATE_API_KEY" => nil, "EBAY_BROWSE_ACCESS_TOKEN" => nil, "BESTBUY_API_KEY" => nil,
      "ETSY_LISTINGS_API_KEY" => nil, "AMAZON_CREATORS_ACCESS_TOKEN" => nil }
  end

  def run(answers)
    output = StringIO.new
    with_env(unset_retailer_keys_env.merge("PORTAGE_ENV_FILE" => @env_path)) do
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "defaults to off, unlike the foundational steps" do
    expect(described_class.new(prompt: nil).default_yes?).to be false
  end

  it "leaves the file untouched when every field is left blank" do
    run("\n\n\n\n\n")

    expect(File.exist?(@env_path)).to be(false)
  end

  it "saves whichever keys were typed, one env var per retailer" do
    run("walmart-key\n\n\netsy-key\n\n")

    expect(Portage::Cli::DotEnv.parse(File.read(@env_path)))
      .to eq("WALMART_AFFILIATE_API_KEY" => "walmart-key", "ETSY_LISTINGS_API_KEY" => "etsy-key")
  end

  it "never prints any of the five keys' own values" do
    output = run("walmart-key\nebay-token\nbestbuy-key\netsy-key\namazon-token\n")

    expect(output).not_to include("walmart-key", "ebay-token", "bestbuy-key", "etsy-key", "amazon-token")
  end

  it "says every offer still ends in hand-off, never a completed purchase" do
    output = run("\n\n\n\n\n")

    expect(output).to include("ends in hand-off")
  end
end

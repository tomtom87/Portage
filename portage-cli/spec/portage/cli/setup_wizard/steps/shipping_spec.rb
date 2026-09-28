require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::Shipping do
  around { |example| Dir.mktmpdir { |dir| @env_path = File.join(dir, ".env") and example.run } }

  def unset_shipping_env = Portage::Cli::ShippingProfile::ENV_VARS.values.to_h { |var| [var, nil] }

  def run(answers)
    output = StringIO.new
    with_env(unset_shipping_env.merge("PORTAGE_ENV_FILE" => @env_path)) do
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "leaves the file untouched when every field is left blank (all Enter)" do
    run("\n" * 9)

    expect(File.exist?(@env_path)).to be(false)
  end

  it "writes only the fields the user actually typed, quoted for round-tripping through DotEnv.parse" do
    # 9 prompts, in ShippingProfile::ENV_VARS order: street, extended, city,
    # region, country, postal, first, last, phone.
    run("1 Main St\n\nErie\n\nUS\n16501\n\n\n\n")

    saved = Portage::Cli::DotEnv.parse(File.read(@env_path))
    expect(saved).to eq("PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie",
                        "PORTAGE_SHIP_COUNTRY" => "US", "PORTAGE_SHIP_POSTAL_CODE" => "16501")
  end

  it "reports what it saved, and to which file" do
    output = run("1 Main St\n\nErie\n\nUS\n16501\n\n\n\n")

    expect(output).to include("Saved").and include(@env_path)
  end

  it "chmods the file 600" do
    run("1 Main St\n\nErie\n\nUS\n16501\n\n\n\n")

    expect(File.stat(@env_path).mode & 0o777).to eq(0o600)
  end
end

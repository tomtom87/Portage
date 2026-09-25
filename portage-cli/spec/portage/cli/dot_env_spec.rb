require "spec_helper"

RSpec.describe Portage::Cli::DotEnv do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
    described_class.instance_variable_set(:@loaded_path, nil)
  end

  def write(body, name: ".env")
    File.join(@dir, name).tap { |path| File.write(path, body) }
  end

  describe ".parse" do
    it "reads KEY=value lines, skipping comments, blank values and junk" do
      parsed = described_class.parse(<<~ENV)
        # comment
        PORTAGE_SHIP_CITY=Erie
        PORTAGE_SHIP_STREET=
        not an assignment
        export PORTAGE_SHIP_COUNTRY=US
        PORTAGE_SHIP_REGION = PA   # trailing comment
      ENV

      expect(parsed).to eq("PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
                           "PORTAGE_SHIP_REGION" => "PA")
    end

    it "unquotes double-quoted values with escapes and single-quoted ones literally" do
      parsed = described_class.parse(%(A="1 Main St, \\"Apt\\" 2"\nB='has # hash'\nC=""\n))

      expect(parsed).to eq("A" => %(1 Main St, "Apt" 2), "B" => "has # hash")
    end
  end

  describe ".load" do
    it "sets unset variables and never overrides the real environment" do
      env = { "PORTAGE_SHIP_CITY" => "Pittsburgh" }
      path = write("PORTAGE_SHIP_CITY=Erie\nPORTAGE_SHIP_COUNTRY=US\n")

      expect(described_class.load(path: path, env: env)).to eq(path)
      expect(env).to eq("PORTAGE_SHIP_CITY" => "Pittsburgh", "PORTAGE_SHIP_COUNTRY" => "US")
      expect(described_class.loaded_path).to eq(path)
    end

    it "does nothing when the file doesn't exist" do
      env = {}

      expect(described_class.load(path: File.join(@dir, "missing"), env: env)).to be_nil
      expect(env).to be_empty
    end

    it "reads PORTAGE_ENV_FILE when no path is given" do
      env = {}
      path = write("PORTAGE_CURRENCY=GBP\n", name: "custom.env")

      with_env("PORTAGE_ENV_FILE" => path) { described_class.load(env: env) }

      expect(env).to eq("PORTAGE_CURRENCY" => "GBP")
    end

    it "defaults to ~/.portage/.env, never ./.env" do
      expect(described_class::DEFAULT_PATH).to eq(File.join(Dir.home, ".portage", ".env"))
    end
  end
end

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

  describe ".update!" do
    it "creates the file (and its directory) with chmod 600 when it doesn't exist yet" do
      path = File.join(@dir, "nested", ".env")

      described_class.update!({ "PORTAGE_SHIP_CITY" => "Erie" }, path: path)

      expect(described_class.parse(File.read(path))).to eq("PORTAGE_SHIP_CITY" => "Erie")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "replaces an existing key in place, never duplicating it" do
      path = write("PORTAGE_SHIP_CITY=Erie\nPORTAGE_SHIP_COUNTRY=US\n")

      described_class.update!({ "PORTAGE_SHIP_CITY" => "Pittsburgh" }, path: path)

      lines = File.readlines(path)
      expect(lines.grep(/PORTAGE_SHIP_CITY/).length).to eq(1)
      expect(described_class.parse(File.read(path))).to eq("PORTAGE_SHIP_CITY" => "Pittsburgh",
                                                           "PORTAGE_SHIP_COUNTRY" => "US")
    end

    it "keeps unrelated lines and comments untouched" do
      path = write("# a comment\nPORTAGE_SHIP_CITY=Erie\n\nPORTAGE_SHIP_COUNTRY=US\n")

      described_class.update!({ "PORTAGE_SHIP_CITY" => "Pittsburgh" }, path: path)

      body = File.read(path)
      expect(body).to include("# a comment")
      expect(body).to include("PORTAGE_SHIP_COUNTRY=\"US\"").or include("PORTAGE_SHIP_COUNTRY=US")
    end

    it "creates a brand-new file at mode 0600 from the very first byte, never via a later chmod" do
      path = File.join(@dir, "fresh.env")

      expect(File).to receive(:open).with(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600).and_call_original

      described_class.update!({ "PORTAGE_SHIP_CITY" => "Erie" }, path: path)
    end

    it "chmods an existing, world-readable file to 0600 before writing into it, not only after" do
      path = write("PORTAGE_SHIP_CITY=Erie\n")
      File.chmod(0o644, path)
      calls = []
      allow(File).to receive(:chmod).and_wrap_original do |original, mode, target|
        calls << :chmod
        original.call(mode, target)
      end
      allow(File).to receive(:open).and_wrap_original do |original, *args, &blk|
        calls << :open
        original.call(*args, &blk)
      end

      described_class.update!({ "PORTAGE_SHIP_CITY" => "Pittsburgh" }, path: path)

      expect(calls.first).to eq(:chmod)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "appends a key that wasn't already on a line" do
      path = write("PORTAGE_SHIP_CITY=Erie\n")

      described_class.update!({ "PORTAGE_SHIP_COUNTRY" => "US" }, path: path)

      expect(described_class.parse(File.read(path))).to eq("PORTAGE_SHIP_CITY" => "Erie",
                                                           "PORTAGE_SHIP_COUNTRY" => "US")
    end

    it "quotes a value with a space or quote so it round-trips through #parse" do
      path = File.join(@dir, ".env")

      described_class.update!({ "PORTAGE_SHIP_STREET" => %(1 Main St, "Apt" 2) }, path: path)

      expect(described_class.parse(File.read(path))).to eq("PORTAGE_SHIP_STREET" => %(1 Main St, "Apt" 2))
    end
  end
end

require "spec_helper"
require "yaml"
require "json"

# The buy plugin's skills are files that both Claude Code and OpenClaw/ClawHub
# read. ClawHub's scan blocks a publish when the frontmatter doesn't match what
# the skill references, and each skill's `version` must follow the buy
# plugin's. ClawHub publishes each skill on its own, so each one is checked
# against only its own folder.
repo_root = File.expand_path("../../..", __dir__)
plugin_dir = File.join(repo_root, "plugins", "buy")
plugin_json = File.join(plugin_dir, ".claude-plugin", "plugin.json")

# Placeholders that look like env vars but are ids the agent substitutes.
placeholders = %w[QUOTE_ID SEARCH_ID]
env_prefixes = /\A(PORTAGE|BRAVE|GOOGLE|ETSY|WALMART|EBAY|BESTBUY|AMAZON)_/

%w[buy product-lookup].each do |skill_name|
  RSpec.describe "#{skill_name} skill frontmatter" do
    skill_dir = File.join(plugin_dir, "skills", skill_name)
    skill_path = File.join(skill_dir, "SKILL.md")

    before { skip "not running inside the Portage monorepo" unless File.exist?(plugin_json) }

    let(:frontmatter) do
      text = File.read(skill_path, encoding: "UTF-8")
      match = text.match(/\A---\n(.*?)\n---\n/m)
      expect(match).not_to be_nil, "SKILL.md must start with a --- frontmatter block"
      YAML.safe_load(match[1])
    end
    let(:openclaw) { frontmatter.dig("metadata", "openclaw") }
    let(:skill_text) do
      Dir.glob(File.join(skill_dir, "**", "*.md")).map { |path| File.read(path, encoding: "UTF-8") }.join("\n")
    end

    it "parses as YAML with the fields both hosts need, named after its folder" do
      expect(frontmatter).to include("name" => skill_name)
      expect(frontmatter["description"]).to be_a(String).and(satisfy { |text| !text.strip.empty? })
      expect(frontmatter["version"]).to match(/\A\d+\.\d+\.\d+\z/)
    end

    it "keeps the skill version in step with the buy plugin version" do
      plugin_version = JSON.parse(File.read(plugin_json)).fetch("version")

      expect(frontmatter["version"]).to eq(plugin_version)
    end

    it "declares the portage binary, its config files and the brew install" do
      expect(openclaw.dig("requires", "bins")).to eq(["portage"])
      expect(openclaw.dig("requires", "config")).to eq(["~/.portage/.env", "~/.portage/config.json"])
      expect(openclaw["install"]).to include(
        a_hash_including("kind" => "brew", "formula" => "tomtom87/portage/portage", "bins" => ["portage"])
      )
      expect(openclaw["homepage"]).to eq("https://portage.readthedocs.io/en/latest/")
    end

    it "declares no env var as required (portage itself works without any)" do
      expect(openclaw.dig("requires", "env")).to be_nil
      expect(openclaw["envVars"]).to all(include("required" => false))
    end

    it "declares every env var the skill and its references name, each with a description" do
      named = skill_text.scan(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/).uniq - placeholders
      named = named.grep(env_prefixes)
      declared = openclaw["envVars"].map { |var| var["name"] }

      expect(named).not_to be_empty
      expect(declared).to include(*named)
      expect(openclaw["envVars"]).to all(include("description" => a_kind_of(String)))
    end

    it "says in every env var's description that the agent never reads or prints its value" do
      expect(openclaw["envVars"].map { |var| var["description"] })
        .to all(include("the agent never reads or prints its value"))
    end

    it "declares nothing the skill never mentions" do
      stale = openclaw["envVars"].map { |var| var["name"] }.reject do |name|
        skill_text.include?(name) || (skill_name == "buy" && name.start_with?("PORTAGE_SHIP_"))
      end

      expect(stale).to be_empty
    end
  end
end

RSpec.describe "buy skill frontmatter, shipping" do
  before { skip "not running inside the Portage monorepo" unless File.exist?(plugin_json) }

  it "declares the shipping address suffix forms the skill lists next to PORTAGE_SHIP_STREET" do
    text = File.read(File.join(plugin_dir, "skills", "buy", "SKILL.md"), encoding: "UTF-8")
    declared = YAML.safe_load(text.match(/\A---\n(.*?)\n---\n/m)[1])
                   .dig("metadata", "openclaw", "envVars").map { |var| var["name"] }

    expect(declared).to include(
      *%w[CITY REGION POSTAL_CODE COUNTRY FIRST_NAME LAST_NAME PHONE].map { |suffix| "PORTAGE_SHIP_#{suffix}" }
    )
  end
end

# The lookup skill is the read-only half of the split ClawHub's scan asked
# for: it must hand purchases to `buy`, and its description must say so.
RSpec.describe "product-lookup skill scope" do
  skill_path = File.join(plugin_dir, "skills", "product-lookup", "SKILL.md")

  before { skip "not running inside the Portage monorepo" unless File.exist?(skill_path) }

  let(:text) { File.read(skill_path, encoding: "UTF-8") }
  let(:description) { YAML.safe_load(text.match(/\A---\n(.*?)\n---\n/m)[1])["description"] }

  it "tells the agent to switch to the buy skill to buy" do
    expect(description).to include("switch to the `buy` skill")
  end

  # Every command in "The commands you may run" table must be one of the
  # read-only ones (checked against portage-cli's code when the skill was
  # written): `find` and `pick --view` save only local search history.
  it "lists only read-only portage commands as ones it may run" do
    section = text[/^## 1\. The commands you may run\n(.*?)^## /m, 1]
    table = section.lines.grep(/\A\|/).join
    commands = table.scan(/`(portage [^`]*)`/).flatten.map { |cmd| cmd.split(/ (?=["\[<A-Z]|--json)/).first }
    read_only = ["portage find --query", "portage index search", "portage index show", "portage check",
                 "portage pick --view", "portage history", "portage doctor"]

    expect(commands).not_to be_empty
    expect(commands).to all(satisfy { |cmd| read_only.include?(cmd) })
  end

  it "names every mutating command it must never run" do
    never_run = text.lines.find { |line| line.start_with?("**Never run**") }

    expect(never_run).to include("`portage buy`", "`approve`", "`pick --choose`", "`payment`", "`policy set`",
                                 "`setup`", "`browser import`", "`index build`", "`index add`",
                                 "`index remove`", "`orders reconcile`")
  end
end

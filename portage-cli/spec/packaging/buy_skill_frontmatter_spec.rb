require "spec_helper"
require "yaml"
require "json"

# The buy skill is one file that both Claude Code and OpenClaw/ClawHub read.
# ClawHub's scan blocks a publish when the frontmatter doesn't match what the
# skill references, and the skill `version` must follow the buy plugin's.
RSpec.describe "buy skill frontmatter" do
  repo_root = File.expand_path("../../..", __dir__)
  skill_dir = File.join(repo_root, "plugins", "buy", "skills", "buy")
  skill_path = File.join(skill_dir, "SKILL.md")
  plugin_json = File.join(repo_root, "plugins", "buy", ".claude-plugin", "plugin.json")

  before { skip "not running inside the Portage monorepo" unless File.exist?(skill_path) }

  let(:frontmatter) do
    text = File.read(skill_path, encoding: "UTF-8")
    match = text.match(/\A---\n(.*?)\n---\n/m)
    expect(match).not_to be_nil, "SKILL.md must start with a --- frontmatter block"
    YAML.safe_load(match[1])
  end
  let(:openclaw) { frontmatter.dig("metadata", "openclaw") }

  # Placeholders that look like env vars but are ids the agent substitutes.
  placeholders = %w[QUOTE_ID SEARCH_ID]
  skill_text = lambda do
    Dir.glob(File.join(skill_dir, "**", "*.md")).map { |path| File.read(path, encoding: "UTF-8") }.join("\n")
  end

  it "parses as YAML with the fields both hosts need" do
    expect(frontmatter).to include("name" => "buy")
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
    named = skill_text.call.scan(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/).uniq - placeholders
    named = named.grep(/\A(PORTAGE|BRAVE|GOOGLE|ETSY)_/)
    declared = openclaw["envVars"].map { |var| var["name"] }

    expect(named).not_to be_empty
    expect(declared).to include(*named)
    expect(openclaw["envVars"]).to all(include("description" => a_kind_of(String)))
  end

  it "declares the shipping address suffix forms the skill lists next to PORTAGE_SHIP_STREET" do
    declared = openclaw["envVars"].map { |var| var["name"] }

    expect(declared).to include(
      *%w[CITY REGION POSTAL_CODE COUNTRY FIRST_NAME LAST_NAME PHONE].map { |suffix| "PORTAGE_SHIP_#{suffix}" }
    )
  end

  it "declares nothing the skill never mentions" do
    text = skill_text.call
    stale = openclaw["envVars"].map { |var| var["name"] }.reject do |name|
      text.include?(name) || name.start_with?("PORTAGE_SHIP_")
    end

    expect(stale).to be_empty
  end
end

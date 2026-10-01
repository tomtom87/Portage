require "spec_helper"
require "yaml"

# The no-CLI skills under the repo's own skills/ folder. A plain-scalar
# description with a ": " in it isn't valid YAML, and an agent host then
# can't load the skill at all, so each one is parsed here.
repo_root = File.expand_path("../../..", __dir__)
skills_dir = File.join(repo_root, "skills")

RSpec.describe "skills/ frontmatter" do
  before { skip "not running inside the Portage monorepo" unless File.directory?(skills_dir) }

  def frontmatter(path)
    match = File.read(path, encoding: "UTF-8").match(/\A---\n(.*?)\n---\n/m)
    expect(match).not_to be_nil, "#{path} must start with a --- frontmatter block"
    YAML.safe_load(match[1])
  end

  it "parses every skill's frontmatter, named after its folder, with a description" do
    paths = Dir.glob(File.join(skills_dir, "*", "SKILL.md"))
    expect(paths).not_to be_empty

    paths.each do |path|
      data = frontmatter(path)
      expect(data["name"]).to eq(File.basename(File.dirname(path)))
      expect(data["description"].to_s.strip).not_to be_empty
    end
  end

  # ClawHub's scan flagged shop-via-ucp's old triggers ("find and/or buy")
  # as too broad, so lookups moved to a read-only browse-via-ucp. Each
  # description points at the other.
  it "splits browsing from buying, each pointing at the other" do
    shop = frontmatter(File.join(skills_dir, "shop-via-ucp", "SKILL.md"))["description"]
    browse = frontmatter(File.join(skills_dir, "browse-via-ucp", "SKILL.md"))["description"]

    expect(shop).to include("use browse-via-ucp instead")
    expect(shop).not_to include("find and/or buy")
    expect(browse).to include("switch to shop-via-ucp")
    expect(browse).to include("never creates, updates or completes a cart or checkout")
  end

  it "keeps shop-via-ucp's fail-closed checkout mismatch guardrail" do
    text = File.read(File.join(skills_dir, "shop-via-ucp", "SKILL.md"), encoding: "UTF-8")

    expect(text).to include("Never pay for a checkout that doesn't match what the user approved.")
  end
end

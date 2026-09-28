require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::BrowserImport::Profiles do
  around do |example|
    Dir.mktmpdir { |dir| @root = dir and example.run }
  end

  def touch(*parts)
    path = File.join(@root, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    path
  end

  it "finds every Chromium profile holding History or Bookmarks, and only those two files" do
    history = touch("Default", "History")
    bookmarks = touch("Profile 2", "Bookmarks")
    touch("Default", "Cookies")
    touch("System Profile", "History")
    FileUtils.mkdir_p(File.join(@root, "Profile 3"))

    profiles = described_class.locate("chrome", root: @root)

    expect(profiles.map { |p| [File.basename(p.dir), p.history, p.bookmarks] })
      .to eq([["Default", history, nil], ["Profile 2", nil, bookmarks]])
    expect(profiles.map(&:family).uniq).to eq(["chromium"])
  end

  it "finds Firefox profiles under Profiles/ (macOS) or directly under the root (Linux)" do
    mac = touch("Profiles", "x.default-release", "places.sqlite")
    expect(described_class.locate("firefox", root: @root).map(&:history)).to eq([mac])

    Dir.mktmpdir do |linux_root|
      path = File.join(linux_root, "y.default", "places.sqlite")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
      expect(described_class.locate("firefox", root: linux_root).map(&:bookmarks)).to eq([path])
    end
  end

  it "treats Safari's root as its one profile" do
    history = touch("History.db")
    bookmarks = touch("Bookmarks.plist")

    expect(described_class.locate("safari", root: @root).map { |p| [p.history, p.bookmarks] })
      .to eq([[history, bookmarks]])
  end

  it "returns nothing for a missing root or an unknown browser" do
    expect(described_class.locate("chrome", root: File.join(@root, "nope"))).to eq([])
    expect(described_class.locate("netscape", root: @root)).to eq([])
  end

  it "only ever allows the history and bookmark files, never a credential/cookie/autofill store" do
    allowed = described_class::ALLOWED_FILES.values.flat_map(&:values).uniq
    expect(allowed).to contain_exactly("History", "Bookmarks", "places.sqlite", "History.db", "Bookmarks.plist")
  end

  it "detects the first browser with a root under the given home" do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p(File.join(home, ".mozilla", "firefox"))
      expect(described_class.detect(home: home)).to eq("firefox")
      expect(described_class.default_root("firefox", home: home)).to eq(File.join(home, ".mozilla", "firefox"))
    end
  end
end

require "spec_helper"
require "fileutils"

RSpec.describe Portage::Cli::InstallDoctor do
  # A fake filesystem per example: a Homebrew prefix with a portage keg (its
  # bin/portage a symlink into the Cellar, like the real formula's), a
  # mise-style Ruby bin holding a `gem install` binstub, and a plain gem
  # directory. Nothing here reads the real PATH or /opt/homebrew.
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  let(:prefix) { File.join(@root, "homebrew") }
  let(:keg) { File.join(prefix, "Cellar", "portage", "0.7.4") }
  let(:brew_gem_dir) { File.join(keg, "libexec", "gems", "portage-cli-0.7.4") }
  let(:brew_bin) { File.join(prefix, "bin") }
  let(:mise_bin) { File.join(@root, "mise", "installs", "ruby", "3.4.1", "bin") }
  let(:plain_gem_dir) { File.join(@root, "mise", "installs", "ruby", "3.4.1", "lib", "gems", "portage-cli-0.7.4") }
  let(:all_loadable) { ->(_name) { { installed: true, loadable: true, version: "1.0.0" } } }

  before do
    FileUtils.mkdir_p([brew_gem_dir, plain_gem_dir, brew_bin])
    executable(File.join(keg, "bin", "portage"))
    File.symlink(File.join("..", "Cellar", "portage", "0.7.4", "bin", "portage"), File.join(brew_bin, "portage"))
    executable(File.join(mise_bin, "portage"))
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    File.chmod(0o755, path)
  end

  def doctor(gem_dir:, path:, adapter_probe: all_loadable, ruby: "/usr/bin/ruby")
    described_class.new(path: path.join(File::PATH_SEPARATOR), homebrew_prefixes: [prefix], gem_dir: gem_dir,
                        ruby: ruby, adapter_probe: adapter_probe)
  end

  def finding(doctor, check) = doctor.findings.find { |f| f.check == check }

  describe "install method" do
    it "reports homebrew, with the keg, when this gem lives under HOMEBREW_PREFIX/Cellar/portage" do
      install = finding(doctor(gem_dir: brew_gem_dir, path: [brew_bin]), "install")

      expect(install.message).to eq("homebrew (#{keg})")
      expect(install.details).to eq(method: "homebrew", path: keg, prefix: prefix)
      expect(install).not_to be_warning
    end

    it "reports homebrew when only the Ruby is under the portage keg" do
      subject = doctor(gem_dir: plain_gem_dir, path: [], ruby: File.join(keg, "libexec", "bin", "ruby"))

      expect(subject).to be_homebrew
    end

    it "reports gem, with the gem's own path, otherwise" do
      install = finding(doctor(gem_dir: plain_gem_dir, path: [mise_bin]), "install")

      expect(install.message).to eq("gem (#{plain_gem_dir})")
      expect(install.details).to eq(method: "gem", path: plain_gem_dir)
    end

    it "doesn't count another formula's Cellar as a portage install" do
      other = File.join(prefix, "Cellar", "ruby", "4.0.7", "lib", "gems", "portage-cli-0.7.4")
      FileUtils.mkdir_p(other)

      expect(doctor(gem_dir: other, path: [])).not_to be_homebrew
    end
  end

  it "reports the Ruby it runs on and the portage-cli version" do
    runtime = finding(doctor(gem_dir: plain_gem_dir, path: [], ruby: "/some/ruby"), "runtime")

    expect(runtime.message).to eq("Ruby #{RUBY_VERSION} (/some/ruby), portage-cli #{Portage::Cli::VERSION}")
    expect(runtime.details).to include(ruby_version: RUBY_VERSION, ruby_path: "/some/ruby",
                                       portage_cli_version: Portage::Cli::VERSION)
  end

  describe "adapters" do
    let(:missing_etsy) do
      lambda do |name|
        next { installed: false, loadable: false, version: nil } if name == "portage-ucp-etsy"

        { installed: true, loadable: true, version: "0.1.4" }
      end
    end

    it "lists every first-party adapter with its version" do
      adapters = finding(doctor(gem_dir: plain_gem_dir, path: []), "adapters")

      expect(adapters.details[:adapters].map { |a| a[:name] })
        .to eq(%w[shopify wix woocommerce bigcommerce magento etsy instagram webmcp decision]
               .map { |n| "portage-ucp-#{n}" })
      expect(adapters.message).to start_with("shopify 1.0.0, wix 1.0.0")
    end

    it "warns when a Homebrew install is missing one, since the formula bundles them all" do
      adapters = finding(doctor(gem_dir: brew_gem_dir, path: [brew_bin], adapter_probe: missing_etsy), "adapters")

      expect(adapters).to be_warning
      expect(adapters.message).to include("etsy", "brew reinstall portage")
    end

    it "only reports a gem install missing one, since adapters are opt-in there" do
      adapters = finding(doctor(gem_dir: plain_gem_dir, path: [], adapter_probe: missing_etsy), "adapters")

      expect(adapters).not_to be_warning
      expect(adapters.message).to include("not installed: etsy")
    end

    it "reports an adapter that raises while loading instead of crashing doctor" do
      probe = ->(name) { name == "portage-ucp-wix" ? raise(LoadError, "broken wix") : all_loadable.call(name) }

      adapters = finding(doctor(gem_dir: plain_gem_dir, path: [], adapter_probe: probe), "adapters")

      wix = adapters.details[:adapters].find { |a| a[:name] == "portage-ucp-wix" }
      expect(wix).to include(loadable: false, error: "LoadError: broken wix")
      expect(adapters.message).to include("failed to load: wix")
    end
  end

  describe "PATH shadowing" do
    it "is quiet about a Homebrew install that's first on PATH, even when a gem copy comes later" do
      path = finding(doctor(gem_dir: brew_gem_dir, path: [brew_bin, mise_bin]), "path")

      expect(path).not_to be_warning
      expect(path.message).to include("#{brew_bin}/portage (this install)")
      expect(path.details[:candidates].map { |c| c[:kind] }).to eq(%w[homebrew other])
    end

    it "warns when an earlier `portage` shadows the Homebrew install, naming the winner and the fix" do
      path = finding(doctor(gem_dir: brew_gem_dir, path: [mise_bin, brew_bin]), "path")

      expect(path).to be_warning
      expect(path.message).to include("runs #{mise_bin}/portage", "not this Homebrew install",
                                      "which -a portage", "gem uninstall portage-cli",
                                      "put #{brew_bin} ahead of #{mise_bin}")
      expect(path.details[:first]).to eq(File.join(mise_bin, "portage"))
    end

    it "resolves symlinks, so the opt/ link and a duplicate PATH entry count as the same keg" do
      opt_bin = File.join(prefix, "opt", "portage", "bin")
      FileUtils.mkdir_p(File.dirname(opt_bin))
      File.symlink(File.join("..", "..", "Cellar", "portage", "0.7.4", "bin"), opt_bin)

      path = finding(doctor(gem_dir: brew_gem_dir, path: [opt_bin, brew_bin, brew_bin, mise_bin]), "path")

      expect(path).not_to be_warning
      expect(path.details[:candidates].length).to eq(2)
    end

    it "doesn't warn a gem install that's first on PATH" do
      path = finding(doctor(gem_dir: plain_gem_dir, path: [mise_bin, brew_bin]), "path")

      expect(path).not_to be_warning
    end

    it "warns a gem install shadowed by a Homebrew one" do
      path = finding(doctor(gem_dir: plain_gem_dir, path: [brew_bin, mise_bin]), "path")

      expect(path).to be_warning
      expect(path.message).to include("runs the Homebrew install (#{brew_bin}/portage)", "brew uninstall portage")
    end

    it "skips non-executable files and reports nothing when no `portage` is on PATH" do
      empty_bin = File.join(@root, "empty")
      FileUtils.mkdir_p(empty_bin)
      File.write(File.join(empty_bin, "portage"), "not executable")

      expect(finding(doctor(gem_dir: plain_gem_dir, path: [empty_bin]), "path")).to be_nil
    end
  end

  it "loads real adapter gems by default, reporting ones not in this bundle as not installed" do
    subject = described_class.new(path: "", gem_dir: plain_gem_dir, homebrew_prefixes: [prefix])

    decision = finding(subject, "adapters").details[:adapters].find { |a| a[:name] == "portage-ucp-decision" }
    expect(decision).to include(installed: true, loadable: true)
  end
end

require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::BrowserProfile::Profile do
  around { |example| Dir.mktmpdir { |dir| @root = dir and example.run } }

  let(:launcher) { instance_double(Portage::Cli::BrowserProfile::Launcher, launch: 123) }
  let(:cdp) { class_double(Portage::Cli::BrowserProfile::Cdp) }

  def profile(**opts)
    described_class.new(browser: "chrome", root: @root, port: 9223, launcher: launcher, cdp: cdp,
                        poll_attempts: 3, poll_interval: 0, sleep_fn: ->(_) {}, **opts)
  end

  it "refuses a non-Chromium-family browser" do
    expect { described_class.new(browser: "firefox") }.to raise_error(ArgumentError, /chrome/)
  end

  describe "#init!" do
    it "creates the dedicated profile directory and nothing else" do
      result = profile.init!

      expect(File.directory?(File.join(@root, "chrome", "profile"))).to be true
      expect(result).to eq(browser: "chrome", dir: File.join(@root, "chrome", "profile"), port: 9223, created: true)
    end
  end

  describe "#status" do
    it "reports not running when the CDP endpoint answers nothing" do
      allow(cdp).to receive(:version).with(port: 9223).and_return(nil)

      expect(profile.status).to eq(running: false, browser: "chrome", dir: File.join(@root, "chrome", "profile"),
                                   port: 9223)
    end

    it "merges in whatever /json/version reports when running" do
      allow(cdp).to receive(:version).with(port: 9223).and_return("Browser" => "Chrome/999")

      status = profile.status
      expect(status[:running]).to be true
      expect(status["Browser"]).to eq("Chrome/999")
    end
  end

  describe "#open!" do
    it "launches the browser when it isn't running yet, waits, then attaches" do
      allow(Portage::Cli::BrowserProfile::Browsers).to receive(:binary_for).and_return("/usr/bin/fake-chrome")
      allow(cdp).to receive(:version).and_return(nil, "Browser" => "Chrome/999")
      allow(cdp).to receive(:list).with(port: 9223).and_return([{ "id" => "1" }])

      result = profile.open!

      expect(launcher).to have_received(:launch).with(binary: kind_of(String), profile_dir: anything, port: 9223)
      expect(result).to eq(running: true, browser: "chrome", dir: File.join(@root, "chrome", "profile"), port: 9223,
                           target: { "id" => "1" })
    end

    it "raises BrowserNotFoundError when the browser isn't installed anywhere" do
      allow(Portage::Cli::BrowserProfile::Browsers).to receive(:binary_for).and_return(nil)
      allow(cdp).to receive(:version).and_return(nil)

      expect { profile.open! }.to raise_error(Portage::Cli::BrowserProfile::BrowserNotFoundError)
    end

    it "raises LaunchError when the port never comes up" do
      allow(Portage::Cli::BrowserProfile::Browsers).to receive(:binary_for).and_return("/usr/bin/fake-chrome")
      allow(cdp).to receive(:version).and_return(nil)

      expect { profile.open! }.to raise_error(Portage::Cli::BrowserProfile::LaunchError)
    end

    it "skips launching (never touches Launcher) when the profile is already running" do
      allow(cdp).to receive(:version).and_return("Browser" => "Chrome/999")
      allow(cdp).to receive(:list).with(port: 9223).and_return([])

      profile.open!

      expect(launcher).not_to have_received(:launch)
    end

    it "opens a new tab at the given URL rather than attaching to an existing one" do
      allow(cdp).to receive(:version).and_return("Browser" => "Chrome/999")
      allow(cdp).to receive(:new_tab).with(port: 9223, url: "https://store.example").and_return({ "id" => "2" })

      result = profile.open!(url: "https://store.example")

      expect(result[:target]).to eq("id" => "2")
    end
  end
end

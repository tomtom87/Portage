require "spec_helper"

RSpec.describe Portage::Cli::BrowserProfile::Launcher do
  it "spawns the browser with a dedicated --user-data-dir and its own --remote-debugging-port, then detaches" do
    spawned = nil
    spawn_stub = lambda do |*args|
      spawned = args
      4242
    end
    allow(Process).to receive(:detach)

    launcher = described_class.new(spawn: spawn_stub)
    pid = launcher.launch(binary: "/usr/bin/fake-chrome", profile_dir: "/tmp/portage-profile", port: 9223)

    expect(pid).to eq(4242)
    expect(Process).to have_received(:detach).with(4242)
    argv = spawned.first(4)
    expect(argv).to eq(["/usr/bin/fake-chrome", "--user-data-dir=/tmp/portage-profile",
                        "--remote-debugging-port=9223", "--no-first-run"])
    expect(spawned).to include("--no-default-browser-check")
  end

  it "never points --user-data-dir at anything but the profile_dir it was given" do
    spawn_stub = lambda do |*args|
      expect(args.grep(/--user-data-dir/)).to eq(["--user-data-dir=/tmp/portage-profile"])
      99
    end
    allow(Process).to receive(:detach)

    described_class.new(spawn: spawn_stub).launch(binary: "/usr/bin/fake-chrome", profile_dir: "/tmp/portage-profile",
                                                  port: 9223)
  end

  it "appends the URL argument when given one" do
    spawned = nil
    spawn_stub = lambda do |*args|
      spawned = args
      1
    end
    allow(Process).to receive(:detach)

    described_class.new(spawn: spawn_stub).launch(binary: "/usr/bin/fake-chrome", profile_dir: "/tmp/x", port: 9223,
                                                  url: "https://example.com")

    expect(spawned).to include("https://example.com")
  end
end

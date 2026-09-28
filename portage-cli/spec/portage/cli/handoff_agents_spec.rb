require "spec_helper"
require "tempfile"
require "benchmark"

RSpec.describe Portage::Cli::HandoffAgents do
  around { |example| Dir.mktmpdir { |dir| @config_path = File.join(dir, "config.json") and example.run } }

  def config(agents)
    path = @config_path
    File.write(path, JSON.generate("handoff_agents" => agents))
    Portage::Cli::Config.load(path: path)
  end

  describe "#lookup" do
    it "returns nil for a name with no config entry" do
      expect(described_class.new(config: config({})).lookup("openclaw")).to be_nil
    end

    it "never invokes an entry with no \"approved\": true" do
      agents = described_class.new(config: config("openclaw" => { "command" => ["openclaw"] }))

      expect(agents.lookup("openclaw")).to be_nil
    end

    it "never invokes an entry explicitly approved: false" do
      agents = described_class.new(config: config("openclaw" => { "command" => ["openclaw"], "approved" => false }))

      expect(agents.lookup("openclaw")).to be_nil
    end

    it "returns a Command for an approved command entry" do
      agents = described_class.new(config: config("openclaw" => { "command" => %w[openclaw handoff],
                                                                  "approved" => true }))

      expect(agents.lookup("openclaw")).to be_a(described_class::Command)
    end

    it "returns a Webhook for an approved webhook entry" do
      agents = described_class.new(config: config("storefront" => { "webhook" => "https://example.com/hook",
                                                                    "approved" => true }))

      expect(agents.lookup("storefront")).to be_a(described_class::Webhook)
    end
  end

  describe described_class::Command do
    let(:payload) { { event: "checkout_handoff", checkout_url: "https://shop.example/c/1" } }

    # Stubs Open3.popen3 to yield fake IO-alikes instead of spawning a real
    # process — Command's own #run contract (write stdin, read stdout/
    # stderr, wait_thr.value) is all this needs to satisfy, matching the
    # "stub system/Open3/Process.spawn, no real subprocess" spec rule.
    def stub_popen3(exit_status: 0, stdout_text: "", stderr_text: "", &assertions)
      status = instance_double(Process::Status, success?: exit_status.zero?, exitstatus: exit_status)
      wait_thr = instance_double(Thread, value: status)
      allow(Open3).to receive(:popen3) do |*args, **kwargs, &block|
        assertions&.call(*args, **kwargs)
        block.call(StringIO.new, StringIO.new(stdout_text), StringIO.new(stderr_text), wait_thr)
      end
    end

    it "never runs a shell string — argv passed as separate elements" do
      stub_popen3 do |env, *argv, **kwargs|
        expect(argv).to eq(%w[openclaw handoff])
        expect(kwargs).to eq(unsetenv_others: true)
        expect(env).to be_a(Hash)
      end

      described_class.new(%w[openclaw handoff]).call(payload)

      expect(Open3).to have_received(:popen3)
    end

    it "writes the payload as JSON on stdin" do
      written = nil
      allow(Open3).to receive(:popen3) do |*_args, **_kwargs, &block|
        stdin = StringIO.new
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        block.call(stdin, StringIO.new, StringIO.new, instance_double(Thread, value: status))
        written = stdin.string
      end

      described_class.new(%w[openclaw]).call(payload)

      expect(JSON.parse(written)).to eq(JSON.parse(JSON.generate(payload)))
    end

    it "passes a scrubbed environment — never PORTAGE_* or other ambient vars" do
      with_env("PORTAGE_SHIP_STREET" => "123 Main St", "SOME_SECRET" => "sshh") do
        stub_popen3 do |env|
          expect(env).not_to have_key("PORTAGE_SHIP_STREET")
          expect(env).not_to have_key("SOME_SECRET")
          expect(env.keys - described_class::Command::ENV_ALLOWLIST).to eq([])
        end

        described_class.new(%w[true]).call(payload)
      end
    end

    it "reports a non-zero exit as not delivered" do
      stub_popen3(exit_status: 1, stderr_text: "boom")

      error = described_class.new(%w[false]).call(payload)

      expect(error).to include("exited").and include("boom")
    end

    it "reports success (nil) on a zero exit" do
      stub_popen3(exit_status: 0)

      expect(described_class.new(%w[true]).call(payload)).to be_nil
    end

    it "reports an empty argv as not delivered without shelling out" do
      expect(Open3).not_to receive(:popen3)

      expect(described_class.new([]).call(payload)).to include("empty")
    end

    it "reports a timeout rather than hanging or raising" do
      allow(Open3).to receive(:popen3).and_raise(Timeout::Error)

      error = described_class.new(%w[sleep 60]).call(payload)

      expect(error).to include("timed out")
    end

    # Real subprocess, real Open3.popen3 (nothing stubbed) — proves the fix
    # for the bug a review caught: Open3.popen3's block form joins wait_thr
    # in its own `ensure` once the block returns, so a timeout that doesn't
    # actually kill the child before leaving that block hangs there instead,
    # and TIMEOUT does nothing. The child writes its own pid to a tmpfile
    # before sleeping, so this can confirm it's actually dead afterward —
    # not just that #call returned.
    it "kills a real hung child on timeout instead of hanging, and the process is dead afterward" do
      stub_const("#{described_class}::TIMEOUT", 0.2)
      stub_const("#{described_class}::KILL_GRACE", 0.2)
      pidfile = Tempfile.new("handoff-agent-pid")
      script = 'File.write(ARGV[0], Process.pid); Signal.trap("TERM") {}; sleep 30'
      command = described_class.new([RbConfig.ruby, "-e", script, pidfile.path])

      elapsed = Benchmark.realtime { @error = command.call(payload) }
      pid = Integer(File.read(pidfile.path))

      expect(@error).to include("timed out")
      expect(elapsed).to be < 5 # well under the real 30s TIMEOUT, and under the child's ignored 30s sleep
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) # no such process — confirmed dead
    ensure
      pidfile&.close!
    end
  end

  describe described_class::Webhook do
    let(:payload) { { event: "checkout_handoff", checkout_url: "https://shop.example/c/1" } }

    it "refuses a non-https URL without making a request" do
      webhook = described_class.new("http://insecure.example/hook")

      error = webhook.call(payload)

      expect(error).to include("https")
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "posts the payload as JSON and reports success on 2xx" do
      stub = stub_request(:post, "https://example.com/hook")
             .with(body: hash_including("event" => "checkout_handoff"),
                   headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: "ok")

      error = described_class.new("https://example.com/hook").call(payload)

      expect(error).to be_nil
      expect(stub).to have_been_requested
    end

    it "reports a non-2xx response as not delivered" do
      stub_request(:post, "https://example.com/hook").to_return(status: 500, body: "nope")

      error = described_class.new("https://example.com/hook").call(payload)

      expect(error).to include("500")
    end

    it "swallows a connection failure into the return value rather than raising" do
      stub_request(:post, "https://example.com/hook").to_raise(SocketError)

      expect { described_class.new("https://example.com/hook").call(payload) }.not_to raise_error
    end
  end
end

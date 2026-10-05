require "json"
require "open3"
require "timeout"
require "uri"
require_relative "config"
require_relative "notifier"
require_relative "user_agent"

module Portage
  module Cli
    # `--handoff-target agent:<name>` (docs/plans/buy-skill-and-local-browser.md
    # Phase 5, decision 3): looks up a named agent in
    # ~/.portage/config.json's `handoff_agents` and, only when it's
    # explicitly `"approved": true`, hands it the same JSON payload
    # `--notify-webhook` sends (Buy#handoff_notify_payload) — checkout URL
    # plus the approved cart summary (items, qty, total, store). No
    # credentials, payment tokens or shipping details beyond what the
    # checkout URL already holds ever go into that payload.
    #
    # Config shape:
    #   "handoff_agents": {
    #     "openclaw": { "command": ["openclaw", "handoff"], "approved": true },
    #     "storefront": { "webhook": "https://example.com/hooks/handoff", "approved": true }
    #   }
    #
    # An entry with no "approved": true (or no entry at all) is never
    # invoked — #lookup returns nil, and the caller (Buy) reports why and
    # falls back to `print` behavior.
    class HandoffAgents
      CONFIG_KEY = "handoff_agents".freeze

      def initialize(config: Config.load)
        @config = config
      end

      # @return [#call, nil] an object responding to #call(payload) that
      #   returns nil on success or a delivery-failure message — nil when
      #   `name` has no config entry, or the entry isn't approved.
      def lookup(name)
        entry = agents[name.to_s]
        return nil unless entry.is_a?(Hash) && entry["approved"] == true

        return Command.new(entry["command"]) if entry["command"]
        return Webhook.new(entry["webhook"]) if entry["webhook"]

        nil
      end

      private

      def agents
        raw = @config.get(CONFIG_KEY)
        raw.is_a?(Hash) ? raw : {}
      end

      # Runs the configured argv (never a shell string — merchant-controlled
      # text never reaches a shell), with the payload as JSON on stdin, a
      # scrubbed environment (only ENV_ALLOWLIST passed through —
      # PORTAGE_*, API keys and every other ambient var are dropped), and a
      # hard timeout that kills the process on expiry. A non-zero exit
      # means "not delivered", same posture as Notifier's non-2xx.
      class Command
        TIMEOUT = 30
        # Grace period between SIGTERM and SIGKILL once TIMEOUT is hit — long
        # enough for a well-behaved process to notice and exit, short enough
        # that a hung/ignoring one doesn't stall the hand-off much further.
        KILL_GRACE = 2
        BODY_EXCERPT = 200
        # Only the basics a well-behaved subprocess needs to run at all —
        # never PORTAGE_*, a payment/API key, or a shipping variable.
        ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TERM TMPDIR TZ].freeze

        def initialize(argv)
          @argv = Array(argv).map(&:to_s)
        end

        def call(payload)
          return "agent command is empty" if @argv.empty?

          stdout, stderr, status = run(payload)
          return nil if status&.success?

          "agent command exited #{status&.exitstatus.inspect}: #{excerpt(stderr, stdout)}"
        rescue Timeout::Error
          "agent command timed out after #{TIMEOUT}s"
        rescue StandardError => e
          "agent command failed: #{e.message}"
        end

        private

        # Reads stdout/stderr on their own threads — same posture as
        # Open3.capture3 — so a child that fills the stderr pipe while this
        # blocks reading stdout to EOF (or vice versa) can't deadlock the
        # hand-off. Open3.popen3's block form always joins `wait_thr` in its
        # own `ensure` once this block returns, so a timeout has to actually
        # kill the child (and wait for it to die) *before* returning from
        # here — otherwise that `ensure` blocks forever on a process nothing
        # is waiting on anymore, and the TIMEOUT constant does nothing.
        def run(payload)
          env = ENV.to_h.slice(*ENV_ALLOWLIST)
          out = nil
          err = nil
          status = nil
          Open3.popen3(env, *@argv, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
            write_and_close(stdin, payload)
            out_thread = Thread.new { stdout.read.to_s }
            err_thread = Thread.new { stderr.read.to_s }
            status = wait_with_timeout(wait_thr)
            out = out_thread.value
            err = err_thread.value
          end
          [out, err, status]
        end

        def wait_with_timeout(wait_thr)
          Timeout.timeout(TIMEOUT) { wait_thr.value }
        rescue Timeout::Error
          kill_and_wait(wait_thr)
          raise
        end

        # SIGTERM first, SIGKILL after KILL_GRACE if it's still alive —
        # either way this doesn't return until `wait_thr.value` resolves, so
        # the process is confirmed dead (and reaped) before #run's caller
        # ever gets to leave the `Open3.popen3` block.
        def kill_and_wait(wait_thr)
          Process.kill("TERM", wait_thr.pid)
          Timeout.timeout(KILL_GRACE) { wait_thr.value }
        rescue Errno::ESRCH
          nil
        rescue Timeout::Error
          kill_quietly(wait_thr.pid)
          wait_thr.value
        end

        def kill_quietly(pid)
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end

        def write_and_close(stdin, payload)
          stdin.write(JSON.generate(payload))
        ensure
          stdin.close
        end

        def excerpt(stderr, stdout) = (stderr.to_s.empty? ? stdout.to_s : stderr.to_s).strip[0, BODY_EXCERPT]
      end

      # POSTs the payload as JSON — https only, through Notifier.post_json
      # (same connection helper as --notify-webhook, with a longer timeout),
      # failures swallowed into the return value rather than raised. Never
      # Notifier#call itself: that falls back to PORTAGE_NOTIFY_WEBHOOK_URL
      # or config, so a blank agent URL would post to the global webhook.
      class Webhook
        TIMEOUT = 10

        def initialize(url)
          @url = url.to_s
        end

        def call(payload)
          return "agent webhook must be https" unless @url.start_with?("https://")

          Notifier.post_json(@url, payload, timeout: TIMEOUT, label: "agent webhook")
        end
      end
    end
  end
end

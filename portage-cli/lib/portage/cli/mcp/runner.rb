require "json"
require "open3"
require "rbconfig"
require "mcp"

module Portage
  module Cli
    module Mcp
      # Runs one `portage ... --json` command for the buyer MCP server
      # (docs/plans/buyer-mcp-server.md): a subprocess of this gem's own
      # exe/portage, never `Cli.run_*` in-process, since every `run_*` writes
      # to `$stdout`, which is the MCP stream. An argv array (no shell), empty
      # stdin, a timeout and an output cap, the same contract as
      # openclaw-plugin/src/runner.ts. Never raises: every failure is an MCP
      # error result.
      class Runner
        MAX_OUTPUT_BYTES = 16 * 1024 * 1024
        TIMEOUT_SECONDS = 120
        STDERR_TAIL = 500

        LIB_DIR = File.expand_path("../../..", __dir__)
        # `-I` the lib this server was loaded from, so the child runs the same
        # release as the parent from a dev checkout or an installed gem.
        DEFAULT_COMMAND = [RbConfig.ruby, "-I", LIB_DIR, File.expand_path("../exe/portage", LIB_DIR)].freeze

        def self.error(message)
          ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], error: true)
        end

        # @param command [Array<String>] the executable and leading args; specs
        #   inject a tiny `ruby -e` child here.
        def initialize(command: DEFAULT_COMMAND, timeout: TIMEOUT_SECONDS, max_bytes: MAX_OUTPUT_BYTES)
          @command = command
          @timeout = timeout
          @max_bytes = max_bytes
        end

        # @return [MCP::Tool::Response]
        def response(args)
          data, error = call(args)
          error ? self.class.error(error) : ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }])
        end

        # Several commands as one result object keyed by section, each section
        # its command's JSON or `{ "error" => message }`, so one failing
        # command doesn't hide the others.
        # @param sections [Hash{Symbol=>Array<String>}]
        def sections(sections)
          data = sections.transform_values do |args|
            value, error = call(args)
            error ? { error: error } : value
          end
          ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }])
        end

        # A command's JSON on stdout is its result whatever the exit code, as
        # in the OpenClaw runner: `find` with no offers, `check` on a
        # hand-off store and `doctor` with warnings all exit 1 with a valid
        # report. Only a run with no valid JSON is an error.
        # @return [Array(Object, nil), Array(nil, String)] parsed JSON, or an error message.
        def call(args)
          stdout, stderr, status, failure = capture(args)
          return [nil, failure] if failure

          [JSON.parse(stdout.force_encoding(Encoding::UTF_8)), nil]
        rescue JSON::ParserError
          err = tail(stderr)
          [nil, "portage #{args.first} exited #{status&.exitstatus || 'on a signal'} without valid JSON output" \
                "#{"; stderr: #{err}" unless err.empty?}"]
        end

        private

        def capture(args)
          Open3.popen3(*@command, *args, pgroup: true) do |stdin, stdout, stderr, wait|
            stdin.close
            out, err, failure = read_all(stdout, stderr)
            kill(wait.pid) if failure
            [out, err, wait.value, failure]
          end
        rescue SystemCallError => e
          [nil, nil, nil, "could not run portage: #{e.message}"]
        end

        # Reads both pipes until EOF, the deadline or the byte cap.
        # @return [Array(String, String, String), Array(String, String, nil)] stdout, stderr, failure message
        def read_all(stdout, stderr)
          buffers = { stdout => +"", stderr => +"" }
          open = buffers.keys
          deadline = now + @timeout
          until open.empty?
            return [*buffers.values, "portage timed out after #{@timeout}s"] unless now < deadline

            read_ready(open, buffers, deadline - now)
            over = buffers.values.sum(&:bytesize) > @max_bytes
            return [*buffers.values, "portage output exceeded the #{@max_bytes}-byte cap"] if over
          end
          [*buffers.values, nil]
        end

        # One `IO.select` round: appends what's readable, drops pipes at EOF.
        def read_ready(open, buffers, wait)
          IO.select(open, nil, nil, wait)&.first&.each do |io|
            chunk = io.read_nonblock(65_536, exception: false)
            if chunk.nil? then open.delete(io)
            elsif chunk != :wait_readable then buffers[io] << chunk
            end
          end
        end

        # The child leads its own process group (`pgroup: true`), so this
        # also stops anything it started.
        def kill(pid)
          Process.kill("KILL", -pid)
        rescue SystemCallError
          nil
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def tail(text)
          t = text.to_s.force_encoding(Encoding::UTF_8).scrub.strip
          t.length > STDERR_TAIL ? "...#{t[-STDERR_TAIL..]}" : t
        end
      end
    end
  end
end

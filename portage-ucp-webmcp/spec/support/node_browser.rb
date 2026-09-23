require "json"
require "open3"
require "rack/mock"
require "uri"

# Ruby half of spec/support/node_browser.js: evaluates page scripts in a node
# process standing in for a browser tab, and answers that tab's fetches from
# `rack_app` — the same Rack app a merchant mounts. Specs that need it are
# tagged `:node` and skipped when node isn't installed.
class NodeBrowser
  HARNESS = File.expand_path("node_browser.js", __dir__)
  TIMEOUT = 10

  def self.available?
    system("node", "--version", out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end

  attr_reader :requests

  def initialize(rack_app: nil, origin: "https://shop.example", origin_header: origin)
    @rack_app = rack_app
    @origin = origin
    @origin_header = origin_header
    @requests = []
    @next_id = 0
    @stdin, @stdout, @stderr, @wait = Open3.popen3({ "PAGE_ORIGIN" => origin }, "node", HARNESS)
  end

  # Evaluates `source` in the tab's global scope, awaiting it if it is a
  # promise, and returns what it resolves to.
  def evaluate(source)
    id = (@next_id += 1)
    write(type: "eval", id: id, source: source)
    loop do
      message = read
      case message["type"]
      when "fetch" then answer(message)
      when "result" then return message["value"] if message["id"] == id
      when "error" then raise "page script failed: #{message['message']}" if message["id"] == id
      end
    end
  end

  def close
    @stdin.close unless @stdin.closed?
    @wait.value
  end

  private

  def answer(message)
    @requests << message
    status, body = @rack_app ? rack_response(message) : [503, '{"error":"no rack app"}']
    write(type: "fetch_response", id: message["id"], status: status, body: body)
  end

  def rack_response(message)
    headers = message["headers"].to_h { |key, value| [rack_header(key), value] }
    env = Rack::MockRequest.env_for(URI.join("#{@origin}/", message["url"]).to_s,
                                    method: message["method"], input: message["body"].to_s, **headers)
    env["HTTP_ORIGIN"] = @origin_header if @origin_header
    status, _headers, body = @rack_app.call(env)
    [status, body.enum_for(:each).to_a.join]
  end

  def rack_header(name)
    return "CONTENT_TYPE" if name.casecmp?("content-type")

    "HTTP_#{name.upcase.tr('-', '_')}"
  end

  def write(message)
    @stdin.puts(JSON.generate(message))
    @stdin.flush
  end

  def read
    raise "node browser timed out: #{drain_stderr}" unless @stdout.wait_readable(TIMEOUT)

    line = @stdout.gets
    raise "node browser exited: #{drain_stderr}" unless line

    JSON.parse(line)
  end

  def drain_stderr
    @stderr.wait_readable(0) ? @stderr.read_nonblock(65_536, exception: false).to_s : ""
  end
end

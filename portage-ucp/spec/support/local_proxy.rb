# frozen_string_literal: true

require "socket"
require "base64"

# A minimal, real, CONNECT-capable TCP proxy for exercising Ruby's stdlib
# HTTP(S)_PROXY support against real Net::HTTP/Faraday connections, without a
# proxy binary (Squid, mitmdump) or a gem. It never actually forwards traffic
# to a target -- there is no network access to depend on in a spec run -- it
# only records the CONNECT/absolute-URI request line and headers a real
# client sent it, then answers just enough (200 for CONNECT, a canned body
# for a plain proxied GET) that the client's own code path completes or fails
# the way it would against a real proxy that then can't reach the target.
#
# See docs/plans/proxy-support.md, Phase 0: this is the "real local proxy"
# spec helper described there, shared (copied, not gemified -- these are
# independently-published gems with no shared dev-dependency) across every
# gem with a Net::HTTP.start/Faraday.new call site.
class LocalProxy
  Recorded = Struct.new(:request_line, :headers, keyword_init: true) do
    def header(name) = headers[name.downcase]
  end

  attr_reader :host, :port

  # @param require_auth [String, nil] "user:pass" -- when set, any request
  #   without a matching Proxy-Authorization is answered 407 instead of 200.
  # @param relay [Boolean] Phase 1 (docs/plans/proxy-support.md) addition:
  #   when true, a successful CONNECT actually dials the requested host:port
  #   for real and pipes bytes both ways, instead of answering 200 and
  #   closing immediately. This is what makes a *chain* of LocalProxy
  #   instances possible -- hop 1's CONNECT to hop 2 has to genuinely reach
  #   hop 2's own accept loop for hop 2 to see and answer the next CONNECT
  #   (or the final plain request) in turn. A hop that can't reach the
  #   requested address (the chain's real, unreachable-by-design final
  #   target in most specs) answers 502 rather than hanging or lying with
  #   a 200 it can't back up -- Support::Connection's tunnel building
  #   treats any non-200 CONNECT response as that hop's own failure.
  # @param responses [Array<String>, nil] Phase 1 addition for the gateway
  #   "never follow a redirect off the gateway" spec: raw HTTP response
  #   byte-strings answered in order to successive non-CONNECT requests
  #   (the last one repeats once exhausted). Defaults to nil, which keeps
  #   the original fixed "200 ok" body for every plain request.
  def initialize(require_auth: nil, relay: false, responses: nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @host = "127.0.0.1"
    @port = @server.addr[1]
    @require_auth = require_auth
    @relay = relay
    @responses = responses
    @requests = Queue.new
    @thread = Thread.new { accept_loop }
  end

  # @return [Recorded, nil] the next request the proxy received, or nil if
  #   none arrived within +timeout+ seconds (meaning the client never
  #   contacted this proxy at all -- itself a meaningful result).
  def last_request(timeout: 3)
    @requests.pop(timeout: timeout)
  rescue ThreadError
    nil
  end

  def stop
    @server.close
  rescue IOError
    nil
  ensure
    @thread.kill
    @thread.join(1)
  end

  private

  def accept_loop
    loop do
      handle(@server.accept)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(client)
    request_line = client.gets
    return client.close unless request_line

    headers = read_headers(client)
    @requests << Recorded.new(request_line: request_line.strip, headers: headers)
    answer(client, request_line, headers)
  rescue StandardError => e
    @requests << Recorded.new(request_line: "ERROR: #{e.class}: #{e.message}", headers: {})
  end

  def answer(client, request_line, headers)
    if @require_auth && !authorized?(headers)
      client.write("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"proxy\"\r\n\r\n")
      client.close
    elsif request_line.start_with?("CONNECT") && @relay
      relay_connect(client, request_line)
    elsif request_line.start_with?("CONNECT")
      # Real proxies would now start relaying bytes; closing here is enough
      # to prove the client reached this proxy and asked it to tunnel --
      # the caller's own request then fails downstream (no real TLS peer),
      # which every call site under test already handles as a normal
      # network error.
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
      client.close
    else
      client.write(next_plain_response)
      client.close
    end
  end

  def next_plain_response
    return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" unless @responses

    @responses.length > 1 ? @responses.shift : @responses.first
  end

  # Dials the CONNECT target for real (a short connect timeout so an
  # unreachable/non-resolving host -- the deliberately-unreachable final
  # target most chain specs use -- fails fast rather than hanging the
  # spec) and, on success, relays bytes in both directions until either
  # side closes. This is what lets a chain of N LocalProxy instances stand
  # in for N real forward proxies: each hop is a completely ordinary
  # CONNECT-capable proxy from its neighbors' point of view.
  def relay_connect(client, request_line)
    target = request_line.split[1].to_s
    host, port = target.split(":")
    upstream = Socket.tcp(host, port.to_i, connect_timeout: 2)
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    pump(client, upstream)
  rescue StandardError
    client.write("HTTP/1.1 502 Bad Gateway\r\n\r\n")
  ensure
    client.close
    upstream&.close
  end

  def pump(left, right)
    threads = [
      Thread.new do
        IO.copy_stream(left, right)
      rescue StandardError
        nil
      end,
      Thread.new do
        IO.copy_stream(right, left)
      rescue StandardError
        nil
      end
    ]
    threads.each(&:join)
  end

  def read_headers(client)
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip if name && value
    end
    headers
  end

  def authorized?(headers)
    headers["proxy-authorization"] == "Basic #{[@require_auth].pack('m0')}"
  end
end

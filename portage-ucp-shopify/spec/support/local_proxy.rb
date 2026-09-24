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
  def initialize(require_auth: nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @host = "127.0.0.1"
    @port = @server.addr[1]
    @require_auth = require_auth
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
    answer(client, request_line, headers)
    client.close
    @requests << Recorded.new(request_line: request_line.strip, headers: headers)
  rescue StandardError => e
    @requests << Recorded.new(request_line: "ERROR: #{e.class}: #{e.message}", headers: {})
  end

  def answer(client, request_line, headers)
    if @require_auth && !authorized?(headers)
      client.write("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"proxy\"\r\n\r\n")
    elsif request_line.start_with?("CONNECT")
      # Real proxies would now start relaying bytes; closing here is enough
      # to prove the client reached this proxy and asked it to tunnel --
      # the caller's own request then fails downstream (no real TLS peer),
      # which every call site under test already handles as a normal
      # network error.
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    else
      body = "ok"
      client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
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

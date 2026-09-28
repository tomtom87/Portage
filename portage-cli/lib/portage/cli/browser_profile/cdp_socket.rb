require "socket"
require "securerandom"
require "digest/sha1"
require "base64"
require "json"
require "uri"
require "timeout"

module Portage
  module Cli
    module BrowserProfile
      # A minimal, dependency-free WebSocket JSON-RPC client for a Chrome
      # DevTools Protocol target — just enough to call `Runtime.evaluate`/
      # `Page.navigate`/`Page.enable` on a page's own `webSocketDebuggerUrl`
      # synchronously, one request at a time. Not a general WebSocket
      # client: text frames only, no compression extension, and no
      # concurrent in-flight requests — Bridge never has two CDP calls
      # outstanding at once, so `#call` blocks until its own response (by
      # `id`) comes back, discarding any unsolicited event frame in
      # between.
      #
      # `transport:` is injectable (any object answering `#write`/`#read`/
      # `#close`, e.g. a real TCPSocket) so specs never open a real socket
      # — see cdp_socket_spec.rb.
      class CdpSocket
        GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze
        TIMEOUT = 30

        def self.connect(ws_url, transport: nil, timeout: TIMEOUT)
          uri = URI.parse(ws_url)
          transport ||= TCPSocket.new(uri.host, uri.port)
          handshake!(transport, uri, timeout: timeout)
          new(transport)
        end

        def initialize(transport)
          @transport = transport
          @next_id = 1
        end

        # @return [Hash] the CDP "result" object.
        # @raise [RuntimeError] the CDP "error" object's message, when the
        #   browser itself rejected the command (bad method/params, no
        #   such target) — distinct from an *evaluated script* raising,
        #   which comes back as a normal result with `exceptionDetails`.
        def call(method, params = {})
          id = @next_id
          @next_id += 1
          send_frame(JSON.generate(id: id, method: method, params: params))
          await_response(id)
        end

        def close
          @transport.close
        rescue StandardError
          nil
        end

        private

        def await_response(id)
          loop do
            message = JSON.parse(read_message)
            next if message["id"] != id

            raise message.dig("error", "message").to_s if message["error"]

            return message["result"] || {}
          end
        end

        # --- outbound framing (client -> server frames MUST be masked,
        # RFC 6455 §5.1) ---

        def send_frame(payload)
          bytes = payload.b
          mask = SecureRandom.random_bytes(4)
          @transport.write(frame_header(0x1, bytes.bytesize) + mask + xor(bytes, mask))
        end

        def send_pong(payload)
          bytes = payload.to_s.b
          mask = SecureRandom.random_bytes(4)
          @transport.write(frame_header(0xA, bytes.bytesize) + mask + xor(bytes, mask))
        end

        def frame_header(opcode, length)
          first = 0x80 | opcode # FIN=1
          return [first, 0x80 | length].pack("CC") if length <= 125
          return [first, 0x80 | 126, length].pack("CCn") if length <= 0xFFFF

          [first, 0x80 | 127, length].pack("CCQ>")
        end

        def xor(bytes, mask)
          bytes.each_byte.with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*")
        end

        # --- inbound framing (server -> client frames are never masked)
        # ---

        # Reads whole logical messages (following any continuation
        # frames), answering pings and dropping pongs, until it has one
        # worth handing to #await_response.
        def read_message
          buffer = +""
          loop do
            fin, opcode, payload = read_one_frame
            case opcode
            when 0x9 then send_pong(payload)
            when 0x8 then raise "CDP socket closed by the browser"
            when 0xA then nil
            else buffer << payload
            end
            return buffer if fin && [0x0, 0x1].include?(opcode)
          end
        end

        def read_one_frame
          b1, b2 = read_exactly(2).unpack("CC")
          fin = b1[7] == 1
          opcode = b1 & 0x0F
          masked = b2[7] == 1
          [fin, opcode, read_payload(b2 & 0x7F, masked)]
        end

        def read_payload(length, masked)
          length = read_exactly(2).unpack1("n") if length == 126
          length = read_exactly(8).unpack1("Q>") if length == 127
          mask = read_exactly(4) if masked
          payload = length.positive? ? read_exactly(length) : +""
          mask ? xor(payload, mask) : payload
        end

        def read_exactly(length)
          return +"" if length <= 0

          Timeout.timeout(TIMEOUT) do
            data = +""
            while data.bytesize < length
              chunk = @transport.read(length - data.bytesize)
              raise "CDP socket closed by the browser" if chunk.nil?

              data << chunk
            end
            data
          end
        end

        # --- handshake (RFC 6455 §4) ---

        def self.handshake!(transport, uri, timeout:)
          key = SecureRandom.base64(16)
          Timeout.timeout(timeout) { transport.write(handshake_request(uri, key)) }
          headers = Timeout.timeout(timeout) { read_headers(transport) }
          verify_handshake!(headers, key)
        end
        private_class_method :handshake!

        def self.handshake_request(uri, key)
          path = uri.path.to_s.empty? ? "/" : uri.path
          path += "?#{uri.query}" if uri.query
          "GET #{path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        end
        private_class_method :handshake_request

        def self.read_headers(transport)
          data = +""
          data << transport.read(1) until data.end_with?("\r\n\r\n")
          data
        end
        private_class_method :read_headers

        def self.verify_handshake!(headers, key)
          raise "CDP handshake failed: #{headers.lines.first}" unless headers.start_with?("HTTP/1.1 101")

          expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
          accept = headers[/Sec-WebSocket-Accept:\s*(\S+)/i, 1]
          raise "CDP handshake failed: unexpected Sec-WebSocket-Accept" unless accept == expected
        end
        private_class_method :verify_handshake!
      end
    end
  end
end

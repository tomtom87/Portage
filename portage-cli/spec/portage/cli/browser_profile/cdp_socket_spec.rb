require "spec_helper"

# A minimal duplex fake standing in for a real TCPSocket — never opens a
# real connection (docs/plans/buy-skill-and-local-browser.md Phase 6's own
# "specs must not launch a real browser — stub process spawn / CDP" rule).
# `written` captures every byte sent; `to_read` is fed back on `#read`,
# one queued chunk per call, matching how CdpSocket reads a fixed-length
# header then the rest of a frame in separate calls.
class FakeCdpTransport
  attr_reader :written

  def initialize(chunks: [])
    @written = +""
    @chunks = chunks.dup
  end

  def write(bytes)
    @written << bytes
  end

  def push(bytes) = @chunks << bytes

  def read(length)
    chunk = @chunks.shift
    return nil if chunk.nil?
    raise "fake transport asked to read more than it was given" if chunk.bytesize > length

    chunk
  end

  def close; end
end

RSpec.describe Portage::Cli::BrowserProfile::CdpSocket do
  # RFC 6455 §1.3's own worked example — a fixed key/accept pair, used so
  # the handshake spec doesn't need to reimplement the SHA1/base64
  # computation to check its own fixture.
  let(:key) { "dGhlIHNhbXBsZSBub25jZQ==" }
  let(:accept) { "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" }

  def frame(payload, opcode: 0x1, fin: true)
    bytes = payload.b
    first = (fin ? 0x80 : 0x00) | opcode
    header = if bytes.bytesize <= 125
               [first, bytes.bytesize].pack("CC")
             else
               [first, 126, bytes.bytesize].pack("CCn")
             end
    header + bytes # server -> client frames are never masked
  end

  def transport_with(handshake_ok: true, frames: [])
    handshake = if handshake_ok
                  "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                else
                  "HTTP/1.1 400 Bad Request\r\n\r\n"
                end
    transport = FakeCdpTransport.new
    (handshake.each_char.to_a + frames.flat_map { |f| f.each_char.to_a }).each { |byte| transport.push(byte) }
    transport
  end

  before { allow(SecureRandom).to receive(:base64).and_return(key) }

  it "connects when the handshake's Sec-WebSocket-Accept matches" do
    socket = described_class.connect("ws://127.0.0.1:9223/devtools/page/1", transport: transport_with)

    expect(socket).to be_a(described_class)
  end

  it "raises when the server doesn't answer 101" do
    expect do
      described_class.connect("ws://127.0.0.1:9223/devtools/page/1", transport: transport_with(handshake_ok: false))
    end.to raise_error(/CDP handshake failed/)
  end

  it "sends a masked text frame carrying the JSON-RPC request" do
    transport = transport_with(frames: [frame({ id: 1, result: {} }.to_json)])
    socket = described_class.connect("ws://127.0.0.1:9223/devtools/page/1", transport: transport)

    transport.written.clear # drop the handshake request bytes; only the frame matters below
    socket.call("Runtime.evaluate", "expression" => "1")

    sent = transport.written
    mask = sent.byteslice(2, 4)
    masked_payload = sent.byteslice(6..)
    unmasked = masked_payload.each_byte.with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
    body = JSON.parse(unmasked)
    expect(body).to eq("id" => 1, "method" => "Runtime.evaluate", "params" => { "expression" => "1" })
    expect(sent.getbyte(1) & 0x80).to eq(0x80) # MASK bit set — client frames must be masked
  end

  it "returns the result of the response whose id matches, skipping other messages" do
    unrelated = frame({ method: "Runtime.consoleAPICalled", params: {} }.to_json)
    response = frame({ id: 1, result: { "value" => 42 } }.to_json)
    transport = transport_with(frames: [unrelated, response])
    socket = described_class.connect("ws://127.0.0.1:9223/devtools/page/1", transport: transport)

    expect(socket.call("Runtime.evaluate")).to eq("value" => 42)
  end

  it "raises the CDP error message when the browser rejects the command" do
    response = frame({ id: 1, error: { "code" => -1, "message" => "no such target" } }.to_json)
    socket = described_class.connect("ws://127.0.0.1:9223/devtools/page/1",
                                     transport: transport_with(frames: [response]))

    expect { socket.call("Bogus.method") }.to raise_error("no such target")
  end

  it "reassembles a message split across continuation frames" do
    payload = { id: 1, result: { "value" => "ok" } }.to_json
    first_half = payload[0, 5]
    second_half = payload[5..]
    frames = [frame(first_half, opcode: 0x1, fin: false), frame(second_half, opcode: 0x0, fin: true)]
    socket = described_class.connect("ws://127.0.0.1:9223/devtools/page/1", transport: transport_with(frames: frames))

    expect(socket.call("Runtime.evaluate")).to eq("value" => "ok")
  end
end

module Portage
  module Ucp
    module WebMcp
      # Base class for every error this gem raises. Subclasses
      # Portage::Ucp::Client::Error so a caller already rescuing the client's
      # errors around a Session call doesn't need a second rescue for the
      # WebMCP transport.
      class Error < Portage::Ucp::Client::Error; end

      # Raised when the browser side couldn't be reached or answered with
      # something this gem can't read: the page has no WebMCP surface at all
      # (neither `document.modelContext`, `navigator.modelContext`, nor
      # `navigator.modelContextTesting`), the driver's evaluate call blew up,
      # or the bridge script's envelope wasn't JSON. A tool that *ran* and
      # reported failure is a Portage::Ucp::Client::ServerError instead — same
      # as over stdio/HTTP.
      class BridgeError < Error; end

      # Raised by Transport when Session asks for an action no registered
      # WebMCP tool answers to (after `tool_names:`/`prefix:` resolution).
      # `#available` lists what the page does register, so a caller wiring a
      # third-party store's own tool names can see what to map to.
      class ToolNotFoundError < Error
        attr_reader :available

        def initialize(message = nil, available: [])
          super(message)
          @available = available
        end
      end
    end
  end
end

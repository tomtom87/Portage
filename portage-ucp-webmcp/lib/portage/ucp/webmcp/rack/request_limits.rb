require "timeout"

module Portage
  module Ucp
    module WebMcp
      module Rack
        # Bounds one CallEndpoint request: how much of its body is ever read,
        # and how long the dispatched call is allowed to run. Split out of
        # CallEndpoint so its own class stays about routing, CORS and
        # JSON-RPC framing.
        class RequestLimits
          DEFAULT_MAX_BODY_BYTES = 1_048_576
          DEFAULT_CALL_TIMEOUT = 30

          TOO_LARGE = :too_large
          TIMED_OUT = :timed_out

          def initialize(max_body_bytes: DEFAULT_MAX_BODY_BYTES, call_timeout: DEFAULT_CALL_TIMEOUT)
            @max_body_bytes = max_body_bytes
            @call_timeout = call_timeout
          end

          # Fast rejection from `Content-Length`, before anything is read.
          def body_too_large?(request)
            length = request.content_length
            !length.nil? && length.to_i > @max_body_bytes
          end

          # At most max_body_bytes + 1 bytes are ever read off the socket, so
          # a request with no `Content-Length` (or one that under-reports)
          # can't be used to buffer an unbounded body first. Returns TOO_LARGE
          # rather than the body once it's clear the cap was exceeded.
          def read_body(request)
            raw = request.body.read(@max_body_bytes + 1)
            return TOO_LARGE if raw && raw.bytesize > @max_body_bytes

            raw.to_s
          end

          # Bounds one call. `nil` call_timeout disables it (Adapter/HTTP
          # timeouts still apply); otherwise yields TIMED_OUT past the
          # deadline instead of raising, so the caller answers a normal
          # JSON-RPC error rather than an uncaught Timeout::Error.
          def call_with_timeout(&)
            return yield unless @call_timeout

            ::Timeout.timeout(@call_timeout, &)
          rescue ::Timeout::Error
            TIMED_OUT
          end
        end
      end
    end
  end
end

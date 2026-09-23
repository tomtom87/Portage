module Portage
  module Ucp
    module Client
      module Transports
        # Session's arguments trimmed to what this gem's own flat-argument
        # server (Portage::Ucp::Mcp::Server -> Dispatcher -> Adapter) takes.
        # `context`/`cart_id`/`handler_id`/`credential_type` are real-UCP
        # wire concerns Session offers for Transports::Http to nest into a
        # request body; the Adapter method signatures have no such keywords,
        # so passing them on would be an ArgumentError on every call.
        #
        # `cart_id` is the exception that needs care: it is only a wire
        # concern on create_checkout (the cart->checkout conversion). On
        # get_cart/update_cart/cancel_cart it *is* the Adapter's own keyword,
        # and dropping it there made every cart read/update/cancel fail with
        # "Missing required arguments: cart_id".
        module LocalArguments
          REMOTE_WIRE_ARGUMENTS = %i[context cart_id handler_id credential_type].freeze
          CART_ID_IS_WIRE_ONLY = %w[create_checkout].freeze

          def self.strip(name, arguments)
            remote = REMOTE_WIRE_ARGUMENTS
            remote -= [:cart_id] unless CART_ID_IS_WIRE_ONLY.include?(name.to_s)
            arguments.except(*remote)
          end
        end
      end
    end
  end
end

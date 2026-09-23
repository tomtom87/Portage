module Portage
  module Ucp
    module WebMcp
      # Arguments cross into JavaScript, so value objects (a
      # Portage::Ucp::CheckoutFulfillment, say) go over as plain hashes.
      module Jsonable
        module_function

        def call(value)
          case value
          when Hash then value.to_h { |k, v| [k.to_s, call(v)] }
          when Array then value.map { |v| call(v) }
          when String, Numeric, true, false, nil then value
          else object(value)
          end
        end

        def object(value)
          return value.to_s if value.is_a?(Symbol) || !value.respond_to?(:to_h)

          call(value.to_h)
        end
      end
    end
  end
end

module Portage
  module Ucp
    module Support
      # UCP's read methods return nil for a missing resource (see
      # Portage::Ucp::Adapter's `@return [..., nil]` annotations), but REST
      # APIs signal that with a 404 rather than an empty success body — so
      # every REST-backed adapter wrapped its reads in the same
      # rescue-404-return-nil block.
      #
      # Only 404 is swallowed: a 401 or 500 is a real failure the caller
      # needs to see, not an absent product.
      module NotFound
        private

        def nil_on_not_found
          yield
        rescue Portage::Ucp::Support::ApiError => e
          raise unless e.status == 404

          nil
        end
      end
    end
  end
end

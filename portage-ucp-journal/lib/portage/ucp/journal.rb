require_relative "journal/version"
require_relative "journal/store"
require_relative "journal/file_store"
require_relative "journal/purchase_journal"

module Portage
  module Ucp
    # Buyer-side purchase journal + the injectable Store abstraction it's
    # built on (design-log §22) — kept out of the dependency-light core gem
    # (portage-ucp §2) since it's an optional consumer add-on, not a
    # payment-safety-critical concern the way TransactionLog/OrderLedger
    # are. A future console or scheduler gem depends on Store the same way.
    module Journal
    end
  end
end

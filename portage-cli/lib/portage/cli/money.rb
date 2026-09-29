module Portage
  module Cli
    # How portage-cli prints an amount in minor units, in one place, so
    # `find`/`history`/`buy` output, Buy's `quote_changed` message and the
    # `approve` summary (docs/plans/human-pick-and-approve.md Phase 2) never
    # disagree on what a total looks like. No FX and no zero-decimal
    # currencies, same as Cli.to_minor_units.
    module Money
      module_function

      # @param amount [Integer] minor units.
      # @param currency [String, nil]
      def format_amount(amount, currency)
        "#{format('%.2f', amount / 100.0)}#{" #{currency}" if currency}"
      end
    end
  end
end

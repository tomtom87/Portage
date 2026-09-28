module Portage
  module Cli
    # docs/plans/webmcp-universal-outbound.md Phase 3, decision 2: even once
    # `--autofill`/`PORTAGE_WEBMCP_AUTOFILL=approve` has opted a run in
    # (WebmcpAutofillMode), nothing is typed into the store's checkout page
    # until the shopper approves, in this prompt, exactly which fields and
    # values are about to be entered — same shape as Phase 2's
    # WebmcpMappingConfirm, applied to autofill instead of a tool mapping.
    #
    # Fields is always contact email + shipping address here — WebmcpFields
    # never builds a payment one — but this class has no opinion on that;
    # it only ever shows the shopper what it was given and asks.
    class WebmcpAutofillConfirm
      # @param interactive [Boolean] false under --json or with no TTY on
      #   stdin — same posture as WebmcpMappingConfirm: no interactive
      #   prompt possible means no autofill, not a guessed default.
      def initialize(interactive:, input: $stdin, output: $stdout)
        @interactive = interactive
        @input = input
        @output = output
      end

      # @param fields [Hash{String=>String}] autocomplete token => value.
      # @return [Boolean] whether the shopper approved filling exactly these
      #   fields. false for an empty `fields` too — nothing to confirm.
      def call(fields)
        return false if !@interactive || fields.empty?

        @output.puts "Autofill is ready to enter this on the store's own checkout page — contact and " \
                     "shipping only, never payment:"
        fields.each { |token, value| @output.puts "  #{token}: #{value}" }
        @output.print "Fill these fields now? [y/N] "
        @output.flush
        @input.gets.to_s.strip.downcase == "y"
      end
    end
  end
end

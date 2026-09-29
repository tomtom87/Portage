module Portage
  module Cli
    # The plain-English `next_step` of a Check report, one sentence per
    # verdict — kept apart from Check so its detection logic stays readable.
    module CheckNextStep
      def self.call(verdict, report)
        case verdict
        when "automated" then automated(report)
        when "webmcp" then "Portage will build the cart; you pay in your browser."
        when "handoff" then adapter(report)
        else unsupported(report)
        end
      end

      def self.automated(report)
        return "Nothing to do — this store speaks UCP natively." if report[:native_ucp]

        "Nothing more to set up — the #{report[:platform]} adapter (#{report.dig(:adapter, :gem)}) is installed " \
          "and answered a live probe."
      end

      def self.adapter(report)
        adapter = report[:adapter]
        return "#{report[:url]} restricts automated purchasing agents. Portage opens the page and you buy." unless
          adapter

        actions = []
        actions << "install #{adapter[:gem]}" unless adapter[:installed]
        actions << "set #{adapter[:missing_env].join(', ')}" if adapter[:missing_env].any?
        return probe_failed(report) if actions.empty?

        "To automate this #{report[:platform]} store (adapters act as the store's owner), " \
          "#{actions.join(' and ')}. Until then Portage opens the store and you buy."
      end

      def self.probe_failed(report)
        reason = report.dig(:live_probe, :reason)
        "The #{report[:platform]} adapter is set up but its live probe failed#{" (#{reason})" if reason}. " \
          "Run `portage doctor`; until then Portage opens the store and you buy."
      end

      def self.unsupported(report)
        webmcp = report[:webmcp]
        note = webmcp[:status] == "skipped" ? " (WebMCP not checked: #{webmcp[:reason]})" : ""
        "No UCP manifest, known platform or WebMCP cart found#{note}. Portage can only open the store " \
          "for you to browse."
      end
      private_class_method :automated, :adapter, :probe_failed, :unsupported
    end
  end
end

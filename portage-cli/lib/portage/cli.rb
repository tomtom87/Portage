require "optparse"
require "json"

require_relative "cli/version"
require_relative "cli/buy"

module Portage
  # `portage` — the single command-line entrypoint for acting as a shopper's
  # agent against any store, native-UCP or not. See Cli::Buy for the actual
  # algorithm; this module is just argument parsing + subcommand dispatch.
  module Cli
    USAGE = <<~USAGE.freeze
      usage: portage buy <url> --query "..." [--qty N] [--payment-token TOKEN]
                                [--yes] [--dry-run] [--json]
    USAGE

    # @param argv [Array<String>]
    # @return [Integer] process exit code
    def self.run(argv)
      command, *rest = argv
      case command
      when "buy" then run_buy(rest)
      else
        warn USAGE
        1
      end
    end

    def self.run_buy(argv)
      options = parse_buy_options(argv)
      return 1 unless options

      json = options.delete(:json)
      report = Buy.new(**options).call
      puts json ? JSON.pretty_generate(report) : format_report(report)
      report[:checkout] || report[:browse] ? 0 : 1
    end
    private_class_method :run_buy

    def self.parse_buy_options(argv)
      url = argv.shift
      unless url && !url.start_with?("-")
        warn USAGE
        return nil
      end

      opts = { url: url, qty: 1, yes: false, dry_run: false }
      buy_option_parser(opts).parse!(argv)
      opts[:query] ||= ""
      opts
    end
    private_class_method :parse_buy_options

    def self.buy_option_parser(opts)
      OptionParser.new do |parser|
        parser.on("--query QUERY") { |v| opts[:query] = v }
        parser.on("--qty N", Integer) { |v| opts[:qty] = v }
        parser.on("--payment-token TOKEN") { |v| opts[:payment_token] = v }
        parser.on("--yes") { opts[:yes] = true }
        parser.on("--dry-run") { opts[:dry_run] = true }
        parser.on("--json") { opts[:json] = true }
      end
    end
    private_class_method :buy_option_parser

    def self.format_report(report)
      lines = ["#{report[:message]} (source: #{report[:source]})"]
      report[:products].each { |p| lines << "  - #{product_line(p)}" }
      lines << "  checkout: #{report[:checkout_url]}" if report[:checkout_url]
      lines.join("\n")
    end
    private_class_method :format_report

    def self.product_line(product)
      product.respond_to?(:title) ? "#{product.id}: #{product.title}" : "#{product['id']}: #{product['title']}"
    end
    private_class_method :product_line
  end
end

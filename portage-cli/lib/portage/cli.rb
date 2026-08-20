require "optparse"
require "json"

require_relative "cli/version"
require_relative "cli/shipping_profile"
require_relative "cli/buy"
require_relative "cli/find"

module Portage
  # `portage` — the single command-line entrypoint for acting as a shopper's
  # agent against any store, native-UCP or not. See Cli::Buy for the buying
  # algorithm and Cli::Find for the "I don't have a URL" search that feeds it;
  # this module is just argument parsing + subcommand dispatch.
  module Cli
    USAGE = <<~USAGE.freeze
      usage: portage buy <url> --query "..." [--qty N] [--payment-token TOKEN]
                                [--product-id ID] [--yes] [--dry-run] [--json]
             portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
             portage find --query "..." [--max-price N] [--limit N] [--json]
    USAGE

    # @param argv [Array<String>]
    # @return [Integer] process exit code
    def self.run(argv)
      command, *rest = argv
      case command
      when "buy" then run_buy(rest)
      when "find" then run_find(rest)
      else
        warn USAGE
        1
      end
    end

    # --- find ---

    def self.run_find(argv)
      options = parse_find_options(argv)
      return 1 unless options

      json = options.delete(:json)
      report = Find.new(**options).call
      puts json ? JSON.pretty_generate(report) : format_find(report)
      report[:offers].any? ? 0 : 1
    end
    private_class_method :run_find

    def self.parse_find_options(argv)
      opts = {}
      find_option_parser(opts).parse!(argv)
      if opts[:query].to_s.strip.empty?
        warn USAGE
        return nil
      end

      opts
    end
    private_class_method :parse_find_options

    def self.find_option_parser(opts)
      OptionParser.new do |parser|
        parser.on("--query QUERY") { |v| opts[:query] = v }
        parser.on("--limit N", Integer) { |v| opts[:limit] = v }
        parser.on("--max-price N", Float) { |v| opts[:max_price] = to_minor_units(v) }
        parser.on("--json") { opts[:json] = true }
      end
    end
    private_class_method :find_option_parser

    # `--max-price 400` means 400 of whatever the offer is priced in, and the
    # comparison happens per-offer in that offer's own currency — no FX
    # conversion, and no attempt to handle zero-decimal currencies like JPY.
    def self.to_minor_units(major) = (major * 100).round
    private_class_method :to_minor_units

    # --- buy ---

    def self.run_buy(argv)
      parsed = parse_buy_options(argv)
      return 1 unless parsed

      url = parsed[:buy][:url] || parsed[:store]
      return execute_buy(parsed, url) if url

      buy_from_search(parsed)
    end
    private_class_method :run_buy

    # `portage buy` with no URL: search first, then buy from the store the
    # caller picks. `--yes` alone deliberately isn't enough to get here —
    # without a URL the merchant would have been chosen by a search ranker
    # rather than by a person, so either `--store` (handled above) or an
    # interactive pick has to name it. Piped/CI runs list the offers and stop.
    def self.buy_from_search(parsed)
      report = Find.new(**parsed[:find]).call
      offer = pick_offer(report, parsed[:json])
      return report[:offers].any? ? 0 : 1 unless offer

      execute_buy(parsed, offer[:store], product_id: offer[:product_id])
    end
    private_class_method :buy_from_search

    def self.pick_offer(report, json)
      output = json ? JSON.pretty_generate(report) : format_find(report)
      puts output
      return nil unless $stdin.tty? && report[:offers].any?

      prompt_for_offer(report[:offers])
    end
    private_class_method :pick_offer

    def self.prompt_for_offer(offers)
      print "\nPick 1-#{offers.length} to buy (Enter to quit): "
      choice = $stdin.gets.to_s.strip
      return nil unless choice.match?(/\A\d+\z/)

      offers[choice.to_i - 1] if choice.to_i.between?(1, offers.length)
    end
    private_class_method :prompt_for_offer

    def self.execute_buy(parsed, url, product_id: nil)
      options = parsed[:buy].merge(url: url)
      options[:product_id] ||= product_id
      report = Buy.new(**options).call
      puts parsed[:json] ? JSON.pretty_generate(report) : format_report(report)
      report[:checkout] || report[:browse] ? 0 : 1
    end
    private_class_method :execute_buy

    def self.parse_buy_options(argv)
      url = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      buy = { url: url, qty: 1, yes: false, dry_run: false }
      parsed = { buy: buy, find: {} }
      buy_option_parser(buy, parsed).parse!(argv)
      buy[:query] ||= ""
      return parsed if url || !buy[:query].strip.empty?

      warn USAGE
      nil
    end
    private_class_method :parse_buy_options

    def self.buy_option_parser(buy, parsed)
      OptionParser.new do |parser|
        parser.on("--qty N", Integer) { |v| buy[:qty] = v }
        parser.on("--payment-token TOKEN") { |v| buy[:payment_token] = v }
        parser.on("--product-id ID") { |v| buy[:product_id] = v }
        parser.on("--yes") { buy[:yes] = true }
        parser.on("--dry-run") { buy[:dry_run] = true }
        parser.on("--json") { parsed[:json] = true }
        add_search_options(parser, buy, parsed)
      end
    end
    private_class_method :buy_option_parser

    # `--query` feeds both halves: it's the store search when there's no URL
    # and the catalog search once a store is settled, so it's registered once
    # here rather than twice on the same parser.
    def self.add_search_options(parser, buy, parsed)
      parser.on("--query QUERY") { |v| parsed[:find][:query] = buy[:query] = v }
      parser.on("--store URL") { |v| parsed[:store] = v }
      parser.on("--limit N", Integer) { |v| parsed[:find][:limit] = v }
      parser.on("--max-price N", Float) { |v| parsed[:find][:max_price] = to_minor_units(v) }
    end
    private_class_method :add_search_options

    # --- output ---

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

    def self.format_find(report)
      lines = [report[:message].to_s]
      report[:offers].each_with_index { |offer, index| lines << "  #{index + 1}. #{offer_line(offer)}" }
      lines.join("\n")
    end
    private_class_method :format_find

    def self.offer_line(offer)
      parts = ["#{offer[:store]} — #{offer[:title]} (#{offer[:product_id]})", format_price(offer)]
      parts << "browse only" unless offer[:checkout]
      parts.join(" — ")
    end
    private_class_method :offer_line

    def self.format_price(offer)
      return "price n/a" unless offer[:amount]

      "#{format('%.2f', offer[:amount] / 100.0)}#{" #{offer[:currency]}" if offer[:currency]}"
    end
    private_class_method :format_price
  end
end

require "optparse"
require "json"

require_relative "cli/version"
require_relative "cli/shipping_profile"
require_relative "cli/catalog_products"
require_relative "cli/buy"
require_relative "cli/find"
require_relative "cli/compare"
require_relative "cli/history"
require_relative "cli/payment_methods"
require_relative "cli/doctor"
require_relative "cli/generate/adapter"
require_relative "cli/generate/agent_profile"

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
             portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                                    [--max-price N] [--json]
             portage history [list] [--purchases|--searches] [--limit N] [--json]
             portage history clear [--purchases|--searches]
             portage payment list [--json]
             portage payment enroll <url> [--label NAME] [--json]
                                    [--scope-merchant HOST ...] [--scope-max-amount N] [--scope-currency CUR]
             portage payment set-default <id>
             portage payment remove <id>
             portage payment freeze <id>
             portage payment revoke <id>
             portage policy show [--json]
             portage policy set [--per-transaction-cap N --currency CUR]
                                 [--rolling-cap N --rolling-window-seconds N --currency CUR]
                                 [--velocity-count N --velocity-window-seconds N]
                                 [--allow HOST ...] [--clear-allowlist]
             portage doctor [--require FILE] [--adapter CLASS_NAME] [--json]
             portage generate adapter NAME [--dir DIR]
             portage generate agent-profile [--out FILE] [--key-out FILE] [--rotate]
    USAGE

    COMMANDS = { "buy" => :run_buy, "find" => :run_find, "compare" => :run_compare,
                 "history" => :run_history, "payment" => :run_payment, "policy" => :run_policy,
                 "doctor" => :run_doctor, "generate" => :run_generate }.freeze

    # @param argv [Array<String>]
    # @return [Integer] process exit code
    def self.run(argv)
      command, *rest = argv
      return send(COMMANDS[command], rest) if COMMANDS.key?(command)

      warn USAGE
      1
    end

    # --- find ---

    def self.run_find(argv)
      options = parse_find_options(argv)
      return 1 unless options

      json = options.delete(:json)
      report = Find.new(**options).call
      History.new.record_search(query: report[:query], offer_count: report[:offers].length,
                                message: report[:message])
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

    # --- compare ---

    def self.run_compare(argv)
      options = parse_compare_options(argv)
      return 1 unless options

      json = options.delete(:json)
      url = options.delete(:url)
      report = Compare.new(origin_url: url, **options).call
      # Recorded as a search, not a purchase — compare never checks out. The
      # query string names the compare so `portage history list` doesn't
      # read it as a plain text search for the origin product's own title.
      History.new.record_search(query: "compare: #{url} (product #{options[:origin_product_id]})",
                                offer_count: report[:offers].length, message: report[:message])
      puts json ? JSON.pretty_generate(report) : format_compare(report)
      report[:offers].any? ? 0 : 1
    end
    private_class_method :run_compare

    def self.parse_compare_options(argv)
      url = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      opts = { identity: [] }
      compare_option_parser(opts).parse!(argv)
      if !url || opts[:origin_product_id].to_s.strip.empty?
        warn USAGE
        return nil
      end

      opts[:url] = url
      opts
    end
    private_class_method :parse_compare_options

    def self.compare_option_parser(opts)
      OptionParser.new do |parser|
        parser.on("--product-id ID") { |v| opts[:origin_product_id] = v }
        parser.on("--id VALUE") { |v| opts[:identity] << v }
        parser.on("--results N", Integer) { |v| opts[:results] = v }
        parser.on("--max-price N", Float) { |v| opts[:max_price] = to_minor_units(v) }
        parser.on("--json") { opts[:json] = true }
      end
    end
    private_class_method :compare_option_parser

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
      record_purchase(report, options[:query]) if report[:checkout]
      puts parsed[:json] ? JSON.pretty_generate(report) : format_report(report)
      report[:checkout] || report[:browse] ? 0 : 1
    end
    private_class_method :execute_buy

    # Only checkout attempts land here — a browse-only report never reached a
    # checkout, so it belongs to search history, not purchase history.
    def self.record_purchase(report, query)
      History.new.record_purchase(
        url: report[:url], query: query, checkout: report[:checkout],
        checkout_status: report[:checkout_status], message: report[:message],
        products: report[:products].map { |p| product_line(p) }
      )
    end
    private_class_method :record_purchase

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

    # --- history ---

    def self.run_history(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : "list"
      case sub
      when "list" then run_history_list(argv)
      when "clear" then run_history_clear(argv)
      else
        warn USAGE
        1
      end
    end
    private_class_method :run_history

    def self.run_history_list(argv)
      opts = { limit: History::MAX_ENTRIES }
      history_option_parser(opts).parse!(argv)
      json = opts.delete(:json)
      kind = opts.delete(:kind)
      history = History.new
      result = { purchases: kind == "searches" ? [] : history.purchases(limit: opts[:limit]),
                 searches: kind == "purchases" ? [] : history.searches(limit: opts[:limit]) }
      puts json ? JSON.pretty_generate(result) : format_history(result)
      0
    end
    private_class_method :run_history_list

    def self.run_history_clear(argv)
      opts = {}
      history_option_parser(opts).parse!(argv)
      History.new.clear(kind: opts[:kind])
      puts "Cleared #{opts[:kind] || 'purchase and search'} history."
      0
    end
    private_class_method :run_history_clear

    def self.history_option_parser(opts)
      OptionParser.new do |parser|
        parser.on("--purchases") { opts[:kind] = "purchases" }
        parser.on("--searches") { opts[:kind] = "searches" }
        parser.on("--limit N", Integer) { |v| opts[:limit] = v }
        parser.on("--json") { opts[:json] = true }
      end
    end
    private_class_method :history_option_parser

    def self.format_history(result)
      lines = ["Purchases:"]
      result[:purchases].each { |p| lines << "  #{history_purchase_line(p)}" }
      lines << "(none)" if result[:purchases].empty?
      lines << "Searches:"
      result[:searches].each { |s| lines << "  #{history_search_line(s)}" }
      lines << "(none)" if result[:searches].empty?
      lines.join("\n")
    end
    private_class_method :format_history

    def self.history_purchase_line(entry)
      "#{Time.at(entry['at'])} — #{entry['url']} (#{entry['query']}) — #{entry['checkout_status'] || entry['message']}"
    end
    private_class_method :history_purchase_line

    def self.history_search_line(entry)
      "#{Time.at(entry['at'])} — \"#{entry['query']}\" — #{entry['offer_count']} offer(s)"
    end
    private_class_method :history_search_line

    # --- payment ---

    # Maps each single-id subcommand to the PaymentMethods method it calls —
    # collapsing what would otherwise be four near-identical `when` branches
    # (each just yielding a different method to #run_payment_mutate) into one
    # table lookup.
    PAYMENT_MUTATIONS = { "set-default" => :make_default, "remove" => :remove,
                          "freeze" => :freeze_method, "revoke" => :revoke }.freeze

    def self.run_payment(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      return run_payment_list(argv) if sub == "list"
      return run_payment_enroll(argv) if sub == "enroll"
      return run_payment_mutate(argv, PAYMENT_MUTATIONS[sub]) if PAYMENT_MUTATIONS.key?(sub)

      warn USAGE
      1
    end
    private_class_method :run_payment

    def self.run_payment_list(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      methods = PaymentMethods.new.list
      puts json ? JSON.pretty_generate(methods) : format_payment_list(methods)
      0
    end
    private_class_method :run_payment_list

    # Shared by set-default/remove/freeze/revoke — each takes exactly one
    # `<id>` positional arg and reports the (now-updated) entry, or fails
    # cleanly for an id that isn't enrolled.
    def self.run_payment_mutate(argv, method_name)
      id = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      unless id
        warn USAGE
        return 1
      end

      entry = PaymentMethods.new.public_send(method_name, id)
      puts "#{entry['label']} (#{entry['id']}) — default: #{entry['default']}, frozen: #{entry['frozen']}"
      0
    rescue PaymentMethods::UnknownMethodError
      warn "No payment method enrolled with id #{id}."
      1
    end
    private_class_method :run_payment_mutate

    def self.parse_payment_enroll_options(argv)
      opts = { scope_merchants: [] }
      OptionParser.new do |parser|
        parser.on("--label NAME") { |v| opts[:label] = v }
        parser.on("--json") { opts[:json] = true }
        parser.on("--scope-merchant HOST") { |v| opts[:scope_merchants] << v }
        parser.on("--scope-max-amount N", Integer) { |v| opts[:scope_max_amount] = v }
        parser.on("--scope-currency CUR") { |v| opts[:scope_currency] = v }
      end.parse!(argv)
      opts[:url] = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      opts
    end
    private_class_method :parse_payment_enroll_options

    # nil (not `{}`) when no --scope-* flag was given at all, so
    # PaymentMethods#enroll's `scope:` default of no-scope-written stays the
    # behavior for a plain `portage payment enroll` — Phase 2's per-token
    # scope is opt-in.
    def self.payment_enroll_scope(opts)
      return nil if opts[:scope_merchants].empty? && !opts[:scope_max_amount]

      { merchants: opts[:scope_merchants], max_amount: opts[:scope_max_amount], currency: opts[:scope_currency] }
        .compact
    end
    private_class_method :payment_enroll_scope

    def self.run_payment_enroll(argv)
      opts = parse_payment_enroll_options(argv)
      unless opts[:url]
        warn USAGE
        return 1
      end

      result = PaymentMethods.new.enroll(opts[:url], label: opts[:label],
                                                     scope: payment_enroll_scope(opts)) do |setup_url|
        puts "Visit this link to add a card, then wait — polling for completion:\n  #{setup_url}"
      end
      puts opts[:json] ? JSON.pretty_generate(result) : format_payment_enroll(result)
      result[:status] == "complete" ? 0 : 1
    rescue PaymentMethods::NotSupportedError => e
      warn e.message
      1
    end
    private_class_method :run_payment_enroll

    # --- policy ---

    def self.run_policy(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      case sub
      when "show" then run_policy_show(argv)
      when "set" then run_policy_set(argv)
      else
        warn USAGE
        1
      end
    end
    private_class_method :run_policy

    def self.run_policy_show(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      policy = Portage::Ucp::Policy.load.to_h
      puts json ? JSON.pretty_generate(policy) : format_policy(policy)
      0
    end
    private_class_method :run_policy_show

    def self.format_policy(policy)
      return "(no policy configured — every check passes)" if policy.empty?

      JSON.pretty_generate(policy)
    end
    private_class_method :format_policy

    def self.parse_policy_set_options(argv)
      opts = { allow: [] }
      OptionParser.new do |parser|
        parser.on("--per-transaction-cap N", Integer) { |v| opts[:per_transaction_cap] = v }
        parser.on("--rolling-cap N", Integer) { |v| opts[:rolling_cap] = v }
        parser.on("--rolling-window-seconds N", Integer) { |v| opts[:rolling_window_seconds] = v }
        parser.on("--currency CUR") { |v| opts[:currency] = v }
        parser.on("--velocity-count N", Integer) { |v| opts[:velocity_count] = v }
        parser.on("--velocity-window-seconds N", Integer) { |v| opts[:velocity_window_seconds] = v }
        parser.on("--allow HOST") { |v| opts[:allow] << v }
        parser.on("--clear-allowlist") { opts[:clear_allowlist] = true }
      end.parse!(argv)
      opts
    end
    private_class_method :parse_policy_set_options

    # Each `--*` group is applied independently and only when its required
    # fields are present — `portage policy set --allow shop.example.com`
    # touches only the allowlist, leaving caps/velocity untouched, so caps
    # and the allowlist can be configured in separate invocations.
    def self.run_policy_set(argv)
      opts = parse_policy_set_options(argv)
      policy = Portage::Ucp::Policy.load
      set_policy_cap(policy, opts)
      set_policy_velocity(policy, opts)
      set_policy_allowlist(policy, opts)
      puts format_policy(policy.to_h)
      0
    end
    private_class_method :run_policy_set

    def self.set_policy_cap(policy, opts)
      if opts[:per_transaction_cap]
        policy.set("per_transaction_cap",
                   { "amount" => opts[:per_transaction_cap], "currency" => require_currency!(opts) })
      end
      return unless opts[:rolling_cap] && opts[:rolling_window_seconds]

      policy.set("rolling_cap", { "amount" => opts[:rolling_cap], "currency" => require_currency!(opts),
                                  "window_seconds" => opts[:rolling_window_seconds] })
    end
    private_class_method :set_policy_cap

    def self.set_policy_velocity(policy, opts)
      return unless opts[:velocity_count] && opts[:velocity_window_seconds]

      policy.set("velocity", { "count" => opts[:velocity_count], "window_seconds" => opts[:velocity_window_seconds] })
    end
    private_class_method :set_policy_velocity

    def self.set_policy_allowlist(policy, opts)
      return policy.set("merchant_allowlist", []) if opts[:clear_allowlist]
      return if opts[:allow].empty?

      policy.set("merchant_allowlist", (policy.merchant_allowlist + opts[:allow]).uniq)
    end
    private_class_method :set_policy_allowlist

    def self.require_currency!(opts)
      opts[:currency] || raise(ArgumentError, "--currency is required alongside a cap")
    end
    private_class_method :require_currency!

    def self.format_payment_list(methods)
      return "(no payment methods enrolled)" if methods.empty?

      methods.map { |m| "#{m['label']} (#{m['id']}) — default: #{m['default']}, frozen: #{m['frozen']}" }.join("\n")
    end
    private_class_method :format_payment_list

    def self.format_payment_enroll(result)
      case result[:status]
      when "complete" then "Enrolled #{result[:label]} (#{result[:id]})."
      when "pending"
        "Timed out waiting for enrollment — finish it at #{result[:setup_url]}, then run " \
        "`portage payment enroll` again."
      else "This store doesn't support payment enrollment."
      end
    end
    private_class_method :format_payment_enroll

    # --- doctor ---

    def self.parse_doctor_options(argv)
      opts = {}
      OptionParser.new do |parser|
        parser.on("--require FILE") { |v| opts[:require] = v }
        parser.on("--adapter CLASS_NAME") { |v| opts[:adapter] = v }
        parser.on("--json") { opts[:json] = true }
      end.parse!(argv)
      opts
    end
    private_class_method :parse_doctor_options

    def self.run_doctor(argv)
      opts = parse_doctor_options(argv)
      require File.expand_path(opts[:require]) if opts[:require]
      adapter_class = opts[:adapter] && Object.const_get(opts[:adapter])

      findings = Doctor.new(adapter_class: adapter_class).call
      puts opts[:json] ? JSON.pretty_generate(findings.map(&:to_h)) : format_doctor(findings)
      findings.empty? ? 0 : 1
    end
    private_class_method :run_doctor

    def self.format_doctor(findings)
      return "No issues found." if findings.empty?

      findings.map { |f| "[#{f.check}] #{f.message}" }.join("\n")
    end
    private_class_method :format_doctor

    # --- generate ---

    def self.run_generate(argv)
      kind, *rest = argv
      case kind
      when "adapter" then run_generate_adapter(rest)
      when "agent-profile" then run_generate_agent_profile(rest)
      else
        warn USAGE
        1
      end
    end
    private_class_method :run_generate

    def self.run_generate_adapter(rest)
      name, *rest = rest
      unless name
        warn USAGE
        return 1
      end

      dir = nil
      OptionParser.new { |parser| parser.on("--dir DIR") { |v| dir = v } }.parse!(rest)
      path = Generate::Adapter.new(name: name, dir: dir).call
      puts "Scaffolded #{path}/"
      0
    end
    private_class_method :run_generate_adapter

    def self.run_generate_agent_profile(rest)
      out = "agent-profile.json"
      key_out = "agent-profile.key.pem"
      rotate = false
      OptionParser.new do |parser|
        parser.on("--out FILE") { |v| out = v }
        parser.on("--key-out FILE") { |v| key_out = v }
        parser.on("--rotate") { rotate = true }
      end.parse!(rest)

      result = Generate::AgentProfile.generate(out: out, key_out: key_out, rotate: rotate)
      puts "Wrote #{result[:profile_path]} (kid #{result[:kid]})"
      puts "Wrote private key to #{result[:private_key_path]} — keep this out of version control " \
           "and off the machine that serves the public profile"
      0
    end
    private_class_method :run_generate_agent_profile

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

    def self.format_compare(report)
      lines = [report[:message].to_s]
      report[:offers].each_with_index { |offer, index| lines << "  #{index + 1}. #{compare_offer_line(offer)}" }
      lines.join("\n")
    end
    private_class_method :format_compare

    def self.compare_offer_line(offer)
      parts = ["[#{offer[:match]}] #{offer[:store]} — #{offer[:title]} (#{offer[:product_id]})", format_price(offer)]
      parts << "browse only" unless offer[:checkout]
      parts.join(" — ")
    end
    private_class_method :compare_offer_line

    def self.format_price(offer)
      return "price n/a" unless offer[:amount]

      "#{format('%.2f', offer[:amount] / 100.0)}#{" #{offer[:currency]}" if offer[:currency]}"
    end
    private_class_method :format_price
  end
end

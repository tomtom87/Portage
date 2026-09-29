require "optparse"
require "json"
require "uri"

require_relative "cli/version"
require_relative "cli/user_agent"
require_relative "cli/shipping_profile"
require_relative "cli/buyer_context"
require_relative "cli/catalog_products"
require_relative "cli/agent_profile_url"
require_relative "cli/offer_sources"
require_relative "cli/index"
require_relative "cli/browser_import"
require_relative "cli/browser_profile"
require_relative "cli/buy"
require_relative "cli/find"
require_relative "cli/compare"
require_relative "cli/history"
require_relative "cli/quotes"
require_relative "cli/money"
require_relative "cli/human_prompt"
require_relative "cli/product_page"
require_relative "cli/approval_policy"
require_relative "cli/offer_choice"
require_relative "cli/pick"
require_relative "cli/approve"
require_relative "cli/payment_methods"
require_relative "cli/proxy_settings"
require_relative "cli/handoff_only"
require_relative "cli/handoff_target"
require_relative "cli/doctor"
require_relative "cli/setup_wizard"
require_relative "cli/handoff_reconciler"
require_relative "cli/handoff_waiter"
require_relative "cli/reconcile_notifier"
require_relative "cli/reconcile_notify"
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
                                [--product-id ID] [--yes] [--dry-run]
                                [--auto-open|--no-auto-open] [--notify-webhook URL]
                                [--handoff-target default|print|profile|agent:NAME]
                                [--decision-backend jev|laya] [--min-confidence N] [--json]
                                [--wait [--wait-timeout DURATION|off]]
             portage buy --offer REF [--qty N] [--yes] [--dry-run] ...
             portage buy --quote QUOTE_ID --yes [--json] ...
             portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
             portage find --query "..." [--max-price N] [--limit N] [--json]
             portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                                    [--max-price N] [--json]
             portage pick [--search LAST|SEARCH_ID] [--via auto|tty|agent] [--json]
                          [--choose REF | --compare REF | --view REF]
             portage approve QUOTE_ID [--via auto|tty|agent] [--relayed-yes | --view] [--json]
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
                                 [--require-approval person|any|off]  (lowering asks at a terminal)
             portage orders reconcile [--checkout ID] [--json]
             portage index build [--sources a,b] [--queries FILE] [--dry-run] [--export DIR] [--json]
             portage index refresh [--sources a,b] [--queries FILE] [--dry-run] [--export DIR] [--json]
             portage index show [--stores|--products] [--json]
             portage index add <url> [--json]
             portage index remove <host> [--json]
             portage index sources [--json]
             portage browser import [--browser chrome|edge|brave|arc|firefox|safari] [--profile-root DIR]
                                    [--history-days 90] [--include-product-pages] [--max-probes 200]
                                    [--exclude HOST,HOST] [--dry-run] [--yes] [--json]
             portage browser profile init|open|status [--browser chrome|edge|brave|arc] [--port N]
                                    [--url URL (open only)] [--json]
             portage doctor [--require FILE] [--adapter CLASS_NAME] [--json]
             portage configure [--require FILE] [--adapter CLASS_NAME] [--json]  (alias for doctor)
             portage setup [--json]  (interactive wizard on a TTY; --json/no TTY: today's doctor report)
             portage generate adapter NAME [--dir DIR]
             portage generate agent-profile [--out FILE] [--key-out FILE] [--rotate]
             portage --version

           proxy flags (buy/find/compare/doctor/payment enroll):
             [--proxy URL] [--proxy-mode forward|gateway] [--proxy-header "Name: value"]
             [--no-proxy HOSTS] [--proxy-route ROUTE=URL|direct] [--proxy-chain URL,URL,...]
             [--proxy-passthrough HEADER] [--proxy-ca FILE] [--no-env-proxy]
    USAGE

    COMMANDS = { "buy" => :run_buy, "find" => :run_find, "compare" => :run_compare,
                 "pick" => :run_pick, "approve" => :run_approve,
                 "history" => :run_history, "payment" => :run_payment, "policy" => :run_policy,
                 "orders" => :run_orders, "index" => :run_index, "browser" => :run_browser,
                 "doctor" => :run_doctor,
                 "configure" => :run_doctor, "setup" => :run_setup, "generate" => :run_generate }.freeze

    VERSION_FLAGS = %w[--version -v version].freeze

    # @param argv [Array<String>]
    # @return [Integer] process exit code
    def self.run(argv)
      command, *rest = argv
      return run_version if VERSION_FLAGS.include?(command)
      return send(COMMANDS[command], rest) if COMMANDS.key?(command)

      warn USAGE
      1
    end

    # So a packaged install (Homebrew's `test do` block, `portage doctor`)
    # can confirm which release it's running without hitting the network.
    def self.run_version
      puts VERSION
      0
    end
    private_class_method :run_version

    # --- proxy (docs/plans/proxy-support.md Phase 2) ---

    # Resolves this command's `--proxy*` flags/env/config.json into a
    # ProxyConfig and installs it as the process-wide default every
    # Support::Connection.start call (buy/find/compare/payment/doctor alike)
    # already reads unless it's handed its own `proxy:` — see ProxySettings'
    # own comment for why. A bad flag or a malformed/protected-header
    # config.json surfaces here as a clean message, never a raw core
    # exception.
    # @return [ProxySettings, nil] nil on a config error (already reported).
    def self.apply_proxy_settings(proxy_flags)
      settings = ProxySettings.new(flags: proxy_flags || {})
      Portage::Ucp::Support::ProxyConfig.current = settings.resolve
      settings
    rescue ProxySettings::ConfigError => e
      warn "portage: #{e.message}"
      nil
    end
    private_class_method :apply_proxy_settings

    # --- find ---

    def self.run_find(argv)
      options = parse_find_options(argv)
      return 1 unless options

      json = options.delete(:json)
      return 1 unless apply_proxy_settings(options.delete(:proxy))

      report = Find.new(**options).call
      report = with_search_id(report, record_find(report))
      puts json ? JSON.pretty_generate(report) : format_find(report)
      report[:offers].any? ? 0 : 1
    end
    private_class_method :run_find

    # @return [Hash, nil] the saved search entry.
    def self.record_find(report)
      History.new.record_search(query: report[:query], offer_count: report[:offers].length,
                                message: report[:message], offers: report[:offers])
    end
    private_class_method :record_find

    # docs/plans/human-pick-and-approve.md Phase 2: the saved search's id,
    # for `portage pick --search`. Additive; absent when nothing was saved.
    def self.with_search_id(report, entry)
      entry.is_a?(Hash) && entry["search_id"] ? report.merge(search_id: entry["search_id"]) : report
    end
    private_class_method :with_search_id

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
      opts[:proxy] = {}
      OptionParser.new do |parser|
        parser.on("--query QUERY") { |v| opts[:query] = v }
        parser.on("--limit N", Integer) { |v| opts[:limit] = v }
        parser.on("--max-price N", Float) { |v| opts[:max_price] = to_minor_units(v) }
        parser.on("--json") { opts[:json] = true }
        ProxySettings.add_options(parser, opts[:proxy])
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
      return 1 unless apply_proxy_settings(options.delete(:proxy))

      report = Compare.new(origin_url: url, **options).call
      report = with_search_id(report, record_compare(url, options[:origin_product_id], report))
      puts json ? JSON.pretty_generate(report) : format_compare(report)
      report[:offers].any? ? 0 : 1
    end
    private_class_method :run_compare

    # Recorded as a search, not a purchase — compare never checks out. The
    # query string names the compare so `portage history list` doesn't
    # read it as a plain text search for the origin product's own title.
    # Its offers are kept with their refs, like `find`'s
    # (docs/plans/human-pick-and-approve.md Phase 2), each carrying the
    # catalog query compare searched with (the origin product's title), so
    # `buy --offer REF` searches for the product, not for "compare: ...".
    def self.record_compare(url, product_id, report)
      offers = report[:offers].map { |offer| offer.merge(query: report[:query]) }
      History.new.record_search(query: "compare: #{url} (product #{product_id})", offer_count: offers.length,
                                message: report[:message], offers: offers)
    end
    private_class_method :record_compare

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
      opts[:proxy] = {}
      OptionParser.new do |parser|
        parser.on("--product-id ID") { |v| opts[:origin_product_id] = v }
        parser.on("--id VALUE") { |v| opts[:identity] << v }
        parser.on("--results N", Integer) { |v| opts[:results] = v }
        parser.on("--max-price N", Float) { |v| opts[:max_price] = to_minor_units(v) }
        parser.on("--json") { opts[:json] = true }
        ProxySettings.add_options(parser, opts[:proxy])
      end
    end
    private_class_method :compare_option_parser

    # --- buy ---

    def self.run_buy(argv)
      parsed = parse_buy_options(argv)
      return 1 unless parsed
      return 1 unless apply_proxy_settings(parsed[:proxy])

      url = parsed[:buy][:url] || parsed[:store]
      parsed[:confidence_check] = confidence_check(parsed, url)
      return 1 unless parsed[:confidence_check]

      parsed[:handoff_target] = handoff_target(parsed, url)
      return 1 unless parsed[:handoff_target]

      dispatch_buy(parsed, url)
    end
    private_class_method :run_buy

    # A saved quote or offer names its own store; otherwise a url does, and
    # with neither the search picks one.
    def self.dispatch_buy(parsed, url)
      return buy_from_quote(parsed) if parsed[:quote]
      return buy_from_offer(parsed) if parsed[:offer]
      return execute_buy(parsed, url) if url

      buy_from_search(parsed)
    end
    private_class_method :dispatch_buy

    # Built and validated up front, same posture as #confidence_check — an
    # unknown --handoff-target/PORTAGE_HANDOFF_TARGET/config.json value is a
    # usage error, reported before a checkout is ever attempted rather than
    # discovered mid hand-off (docs/plans/buy-skill-and-local-browser.md
    # Phase 5).
    def self.handoff_target(parsed, url)
      HandoffTarget.new(override: parsed[:buy][:handoff_target])
    rescue ArgumentError => e
      invalid_buy_option(e.message, url: url, json: parsed[:json])
    end
    private_class_method :handoff_target

    # `portage buy` with no URL: search first, then buy from the store the
    # caller picks. `--yes` alone deliberately isn't enough to get here —
    # without a URL the merchant would have been chosen by a search ranker
    # rather than by a person, so either `--store` (handled above) or an
    # interactive pick has to name it. Runs with no terminal (or under
    # --json) list the offers and stop.
    def self.buy_from_search(parsed)
      report = Find.new(**parsed[:find]).call
      report = with_search_id(report, record_find(report))
      offer = pick_offer(report, parsed[:json])
      return report[:offers].any? ? 0 : 1 unless offer

      parsed[:offer_ref] = offer[:offer_ref]
      parsed[:page] = { title: offer[:title], url: offer[:url] }
      execute_buy(parsed, offer[:store], product_id: offer[:product_id])
    end
    private_class_method :buy_from_search

    # `--offer REF`: the store, product and query come from the saved
    # `find` that produced the ref, as if they'd been passed as flags.
    def self.buy_from_offer(parsed)
      offer = History.new.offer(parsed[:offer])
      unless offer
        invalid_buy_option("No saved offer #{parsed[:offer]} — run `portage find` again.",
                           url: nil, json: parsed[:json], outcome: "offer_not_found")
        return 1
      end

      parsed[:offer_ref] = parsed[:offer]
      parsed[:page] = { title: offer["title"], url: offer["url"] }
      parsed[:buy][:query] = offer["query"].to_s
      execute_buy(parsed, offer["store"], product_id: offer["product_id"])
    end
    private_class_method :buy_from_offer

    # `--quote QUOTE_ID`: buys what a `--dry-run` showed. Buy is handed the
    # quoted total as a cap and refuses (`quote_changed`) if the real
    # checkout costs more, so the person's approval always covers the total
    # that gets charged. The quote is spent by #settle_quote, once the run
    # purchases or hands off.
    #
    # docs/plans/human-pick-and-approve.md Phase 2: a real run (`--yes`, not
    # `--dry-run`) of a quote that isn't approved enough for
    # `--require-approval` is refused with `needs_approval` before Buy
    # runs, so it never charges and never hands off.
    def self.buy_from_quote(parsed)
      quote = usable_quote(parsed)
      return 1 unless quote

      level = ApprovalPolicy.level
      if real_run?(parsed) && !ApprovalPolicy.satisfied?(quote, level)
        return refuse_unapproved_quote(parsed, quote, level)
      end

      parsed[:quote_record] = quote
      buy = parsed[:buy]
      buy.merge!(qty: quote["qty"], product_id: quote["product_id"], query: quote["query"].to_s)
      buy.merge!(quote_total: quote["total"], quote_currency: quote["currency"])
      execute_buy(parsed, quote["store"])
    end
    private_class_method :buy_from_quote

    def self.usable_quote(parsed)
      quote = Quotes.new.find(parsed[:quote])
      unless quote
        return invalid_buy_option("No saved quote #{parsed[:quote]} — run `portage buy ... --dry-run --json` " \
                                  "for a new one.", url: nil, json: parsed[:json], outcome: "quote_not_found")
      end
      return quote unless quote["used_at"]

      invalid_buy_option("Quote #{parsed[:quote]} has already been used — dry-run again for a new one.",
                         url: quote["store"], json: parsed[:json], outcome: "quote_used")
    end
    private_class_method :usable_quote

    def self.refuse_unapproved_quote(parsed, quote, level)
      summary = Approve.summary(quote)
      report = { url: quote["store"], checkout_url: nil, products: [], warnings: [], source: "none", browse: false,
                 checkout: false }.merge(Approve.needs_approval(summary, message: approval_message(summary, level)))
      print_buy_report(report, nil, parsed[:json])
      buy_exit_code(report)
    end
    private_class_method :refuse_unapproved_quote

    # With a terminal (and no --json) the person picks there, through the
    # same HumanPrompt numbered pick `portage pick` uses; otherwise the
    # offers are printed and nothing is bought.
    def self.pick_offer(report, json)
      prompt = HumanPrompt.new(json: json)
      unless prompt.tty? && report[:offers].any?
        puts json ? JSON.pretty_generate(report) : format_find(report)
        return nil
      end

      prompt_for_offer(prompt, report)
    end
    private_class_method :pick_offer

    def self.prompt_for_offer(prompt, report)
      prompt.say(report[:message].to_s)
      choices = report[:offers].map { |offer| OfferChoice.for(offer) }
      index = prompt.choose("Pick one to buy", choices, view: OfferChoice.method(:view_message))
      index && report[:offers][index]
    end
    private_class_method :prompt_for_offer

    # docs/plans/human-pick-and-approve.md Phase 2: under
    # `--require-approval any|person` a real `--yes` run with no approved
    # `--quote` is run as a dry run instead — never charged, never handed
    # off — which prices it and saves a quote, and the report becomes
    # `needs_approval` naming that quote and the next steps. Done here, not
    # in Buy, so Buy's library callers aren't governed by the CLI policy.
    def self.execute_buy(parsed, url, product_id: nil)
      gated = approval_gate?(parsed)
      parsed[:buy] = parsed[:buy].merge(yes: false, dry_run: true) if gated
      options = buy_options(parsed, url, product_id: product_id)
      report = Buy.new(**options).call
      record_buy(report, options[:query])
      report = settle_quote(report, parsed, options)
      report = needs_approval_report(report) if gated
      result = parsed[:wait] ? wait_for_handoff(report, parsed) : nil
      print_buy_report(report, result, parsed[:json])
      buy_exit_code(report)
    end
    private_class_method :execute_buy

    def self.buy_options(parsed, url, product_id: nil)
      options = parsed[:buy].merge(url: url, confidence_check: parsed[:confidence_check],
                                   handoff_target: parsed[:handoff_target], json: !parsed[:json].nil?)
      options[:product_id] ||= product_id
      options[:webmcp_bridge] = profile_webmcp_bridge(url) if parsed[:handoff_target].profile?
      options
    end
    private_class_method :buy_options

    # `needs_approval` exits 0 like Buy's own `needs_confirmation`: the run
    # did what it could and is waiting on the person.
    def self.buy_exit_code(report)
      report[:outcome] == "needs_approval" || report[:checkout] || report[:browse] ? 0 : 1
    end
    private_class_method :buy_exit_code

    def self.real_run?(parsed) = parsed[:buy][:yes] && !parsed[:buy][:dry_run]
    private_class_method :real_run?

    # An approved quote already passed ApprovalPolicy in #buy_from_quote.
    def self.approval_gate?(parsed)
      real_run?(parsed) && !parsed[:quote_record] && ApprovalPolicy.level != "off"
    end
    private_class_method :approval_gate?

    # A gated run that got as far as a priced checkout saved a quote; one
    # that didn't (no match, a dead end) is reported as it is — nothing
    # was bought either way.
    def self.needs_approval_report(report)
      quote = report[:quote_id] && Quotes.new.find(report[:quote_id])
      return report unless quote

      summary = Approve.summary(quote)
      report.merge(Approve.needs_approval(summary, message: approval_message(summary, ApprovalPolicy.level)))
    end
    private_class_method :needs_approval_report

    def self.approval_message(summary, level)
      id = summary[:quote_id]
      held = if summary[:approved_by]
               "Quote #{id} was approved by #{summary[:approved_by]}, which require_approval #{level} doesn't accept."
             else
               "Quote #{id} (#{Approve.describe(summary)}) needs approval first (require_approval: #{level})."
             end
      how = level == "person" ? "`portage approve #{id} --via tty` at a terminal" : "`portage approve #{id}`"
      "Nothing was bought. #{held} Approve it with #{how}, then run `portage buy --quote #{id} --yes`."
    end
    private_class_method :approval_message

    # A dry run saves a quote and reports its `quote_id`. A run of a saved
    # quote spends it once it purchases or hands off; any other outcome
    # (needs_confirmation, a dry run, an error) leaves it usable.
    def self.settle_quote(report, parsed, options)
      quote = parsed[:quote_record]
      if quote
        Quotes.new.consume(quote["quote_id"]) if report[:outcome] == "purchased" || report[:handoff]
        return report[:outcome] == "quote_changed" ? report.merge(quote_id: quote["quote_id"]) : report
      end
      return report unless report[:outcome] == "dry_run"

      saved = Quotes.new.create(offer_ref: parsed[:offer_ref], store: report[:url],
                                product_id: options[:product_id], query: options[:query], qty: options[:qty],
                                total: report_total(report), currency: report[:currency],
                                **quote_page(report, parsed))
      saved ? report.merge(quote_id: saved["quote_id"]) : report
    end
    private_class_method :settle_quote

    # What `portage approve` shows (docs/plans/human-pick-and-approve.md
    # Phase 2): the title of what's in the checkout, else the picked
    # offer's, and the offer's product page when the buy came from one.
    def self.quote_page(report, parsed)
      page = parsed[:page] || {}
      { title: Array(report[:items]).first&.dig(:title) || page[:title], url: page[:url] }
    end
    private_class_method :quote_page

    # docs/plans/buy-skill-and-local-browser.md Phase 6: `--handoff-target
    # profile` gives `portage buy` a browser of its own — the Portage
    # profile — so it's attached here as Buy's `webmcp_bridge:`, exactly
    # the seam Buy#initialize's own doc comment already names as "the only
    # option from the portage buy CLI" before this phase existed. Never
    # raises: any failure to attach (portage-ucp-webmcp not installed, the
    # profile not running, a bad target) just means Buy runs with no
    # bridge at all — its dead-end hand-off to "profile" then reports that
    # the browser isn't attached (see #dispatch_to_target's "profile"
    # case) rather than this crashing the whole buy.
    def self.profile_webmcp_bridge(url)
      return nil unless Webmcp.available?

      profile = BrowserProfile::Profile.new
      return nil unless profile.status[:running]

      full_url = absolute_url(url)
      target = browser_profile_target(profile, full_url)
      ws_url = target && target["webSocketDebuggerUrl"]
      return nil unless ws_url

      socket = BrowserProfile::CdpSocket.connect(ws_url)
      allowlist = BrowserProfile::Allowlist.new(hosts: [URI(full_url).host])
      BrowserProfile::Bridge.new(socket: socket, allowlist: allowlist)
    rescue StandardError
      nil
    end
    private_class_method :profile_webmcp_bridge

    # Same "bare host gets an https:// prefix" normalization Buy#initialize
    # applies to the same `url` — done again here since this runs before
    # Buy exists to do it, and a bare host like "shop.example" isn't a
    # URI CDP's own `/json/new` or Runtime.evaluate's `window.location`
    # comparisons can parse a host out of otherwise.
    def self.absolute_url(url)
      raw = url.to_s.strip
      raw =~ %r{\Ahttps?://}i ? raw : "https://#{raw}"
    end
    private_class_method :absolute_url

    # An existing tab already on this store's host, so a shopper who's
    # mid-session there isn't yanked to a fresh one; otherwise a brand new
    # tab navigated straight to `url`.
    def self.browser_profile_target(profile, url)
      host = URI(url).host
      existing = BrowserProfile::Cdp.list(port: profile.port)
                                    .find { |t| t["type"] == "page" && same_host?(t["url"], host) }
      existing || BrowserProfile::Cdp.new_tab(port: profile.port, url: url)
    end
    private_class_method :browser_profile_target

    def self.same_host?(url, host)
      URI(url.to_s).host == host
    rescue URI::InvalidURIError
      false
    end
    private_class_method :same_host?

    # docs/plans/handoff-reconcile.md Phase 3 — `portage buy --wait`. A
    # no-op (returns nil) whenever there's nothing to wait on: --dry-run
    # never hands off at all, and a completed/browse-only/dead-end report
    # has no pending shopper record either. Otherwise polls
    # `HandoffReconciler` through `HandoffWaiter` until it settles or its
    # deadline passes.
    #
    # Under --json, every event streams to stdout as it happens (NDJSON) —
    # the initial hand-off, then a line per checkout-status change, then the
    # settle, so a calling agent reading stdout live never has to guess
    # whether it's still waiting. Under plain output, nothing streams here:
    # the forced "terminal" notify channel (see #wait_notifier) prints its
    # own line when it settles, and the final report follows exactly as it
    # does without --wait.
    def self.wait_for_handoff(report, parsed)
      return nil unless report[:handoff] && report[:checkout_id]

      transaction_log = Portage::Ucp::Support::TransactionLog.new
      record = pending_shopper_record(report[:checkout_id], transaction_log)
      return nil unless record

      json = parsed[:json]
      emit_ndjson(handoff_event(report)) if json
      reconciler = HandoffReconciler.new(transaction_log: transaction_log, notifier: wait_notifier(json))
      waiter = HandoffWaiter.new(reconciler: reconciler, transaction_log: transaction_log,
                                 wait_timeout_override: parsed[:wait_timeout])
      waiter.call(record) { |event, result| emit_wait_event(event, result, json) }
    end
    private_class_method :wait_for_handoff

    def self.pending_shopper_record(checkout_id, transaction_log)
      transaction_log.each_record.find { |r| r["checkout_id"] == checkout_id && r["settled_by"] == "shopper" }
    end
    private_class_method :pending_shopper_record

    # `terminal` is forced on for a plain-text wait (see ReconcileNotify) so
    # the shopper sees a line the moment it settles even with nothing
    # configured. Never forced under --json: that channel prints plain text,
    # which would corrupt the NDJSON stream this method's caller is also
    # writing to the same stdout.
    def self.wait_notifier(json)
      ReconcileNotifier.new(channels: ReconcileNotify.resolve(extra: json ? [] : ["terminal"]))
    end
    private_class_method :wait_notifier

    def self.handoff_event(report)
      { event: "handoff", checkout_id: report[:checkout_id], checkout_url: report[:checkout_url],
        reason: report[:outcome] }
    end
    private_class_method :handoff_event

    # Only `:settled` ever reaches stdout as `handoff_settled` — a timeout or
    # an interrupted wait leaves `result.settled` false, and that's already
    # visible in the final report object this event stream ends with, so a
    # second, redundant "gave up" event isn't needed.
    def self.emit_wait_event(event, result, json)
      return unless json

      case event
      when :status then emit_ndjson({ event: "handoff_status", status: result.checkout_status })
      when :settled
        emit_ndjson({ event: "handoff_settled", result: result.status, resolution: result.resolution,
                      order_id: result.order_id, amount: result.amount, currency: result.currency }.compact)
      end
    end
    private_class_method :emit_wait_event

    def self.emit_ndjson(payload) = puts JSON.generate(payload)
    private_class_method :emit_ndjson

    def self.print_buy_report(report, result, json)
      report = report.merge(reconcile: result.to_h) if result
      puts json ? JSON.pretty_generate(report) : format_report(report)
    end
    private_class_method :print_buy_report

    # Built before the buy starts (and before the search, when there's no
    # URL), so a bad --min-confidence, or a bad PORTAGE_MIN_CONFIDENCE with
    # a backend enabled, stops the run up front rather than after a
    # checkout already exists.
    def self.confidence_check(parsed, url)
      ConfidenceCheck.new(**parsed[:confidence])
    rescue ArgumentError => e
      invalid_buy_option(e.message, url: url, json: parsed[:json])
    end
    private_class_method :confidence_check

    # A buy refused before it started. Under --json that's a report like
    # any other, with outcome `invalid_option`, so an agent loop reading
    # stdout gets JSON rather than nothing and a line on stderr.
    # @return [nil]
    def self.invalid_buy_option(message, url:, json:, outcome: "invalid_option")
      unless json
        warn message
        return nil
      end

      puts JSON.pretty_generate(url: url, checkout_url: nil, products: [], warnings: [], source: "none",
                                outcome: outcome, browse: false, checkout: false, message: message)
      nil
    end
    private_class_method :invalid_buy_option

    # A buy that created a checkout is a purchase entry, whatever its
    # outcome. One that never got that far (no match, browse-only, dead end,
    # a store or adapter error) is a search at that store, so "what did I
    # already buy" never lists a checkout that doesn't exist.
    def self.record_buy(report, query)
      history = History.new
      unless report[:checkout_id]
        return history.record_search(query: query, url: report[:url], offer_count: report[:products].length,
                                     message: report[:message])
      end

      history.record_purchase(
        url: report[:url], query: query, outcome: report[:outcome], source: report[:source],
        checkout_id: report[:checkout_id], checkout_status: report[:checkout_status],
        checkout_url: report[:checkout_url], total: report_total(report), currency: report[:currency],
        items: Array(report[:items]).map { |item| item.transform_keys(&:to_s) }, message: report[:message]
      )
    end
    private_class_method :record_buy

    def self.report_total(report)
      Portage::Ucp::Support::Totals.amount(report[:totals])
    end
    private_class_method :report_total

    # A flag OptionParser can't read (`--min-confidence high`, `--qty two`,
    # an unknown flag) is refused the same way as an out-of-range
    # threshold. `--json` is looked for up front, since parsing stops at
    # the bad flag and may never reach it.
    def self.parse_buy_options(argv)
      url = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      buy = { url: url, qty: 1, yes: false, dry_run: false }
      parsed = { buy: buy, find: {}, confidence: {} }
      json = argv.include?("--json")
      parsed[:proxy] = {}
      parser = buy_option_parser(buy, parsed)
      ProxySettings.add_options(parser, parsed[:proxy])
      parser.parse!(argv)
      url = reinterpret_bare_query(url, buy, parsed)
      buy[:query] ||= ""
      return parsed if buy_target?(url, buy, parsed)

      warn USAGE
      nil
    rescue OptionParser::ParseError => e
      invalid_buy_option(e.message, url: url, json: json)
    end
    private_class_method :parse_buy_options

    def self.buy_target?(url, buy, parsed)
      url || !buy[:query].strip.empty? || parsed[:offer] || parsed[:quote]
    end
    private_class_method :buy_target?

    # Bare arg is normally the store URL (`portage buy <url> --query "..."`),
    # but `portage buy "coffee"` — no --query, and "coffee" doesn't look like
    # a URL/domain — means the same thing as `portage buy --query "coffee"`:
    # search first, then buy from whatever the caller picks. Only reinterpret
    # when no --query was already given, so `portage buy shop.com --query
    # "coffee"` keeps treating "shop.com" as the store.
    def self.reinterpret_bare_query(url, buy, parsed)
      return url unless url && buy[:query].to_s.strip.empty? && !url_like?(url)

      buy[:url] = nil
      parsed[:find][:query] = buy[:query] = url
      nil
    end
    private_class_method :reinterpret_bare_query

    def self.url_like?(text) = text.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || text.include?(".")
    private_class_method :url_like?

    def self.buy_option_parser(buy, parsed)
      OptionParser.new do |parser|
        parser.on("--qty N", Integer) { |v| buy[:qty] = v }
        parser.on("--payment-token TOKEN") { |v| buy[:payment_token] = v }
        parser.on("--product-id ID") { |v| buy[:product_id] = v }
        parser.on("--yes") { buy[:yes] = true }
        parser.on("--dry-run") { buy[:dry_run] = true }
        parser.on("--autofill") { buy[:autofill] = true }
        parser.on("--json") { parsed[:json] = true }
        add_handoff_options(parser, buy)
        add_wait_options(parser, parsed)
        add_search_options(parser, buy, parsed)
        add_confidence_options(parser, parsed[:confidence])
      end
    end
    private_class_method :buy_option_parser

    # The opt-in confidence gate in front of a `--yes` completion (see
    # ConfidenceCheck) — both default to their PORTAGE_* env vars.
    def self.add_confidence_options(parser, confidence)
      parser.on("--decision-backend NAME") { |v| confidence[:backend] = v }
      parser.on("--min-confidence N", Float) { |v| confidence[:threshold] = v }
    end
    private_class_method :add_confidence_options

    def self.add_handoff_options(parser, buy)
      parser.on("--[no-]auto-open") { |v| buy[:auto_open] = v }
      parser.on("--notify-webhook URL") { |v| buy[:notify_webhook] = v }
      parser.on("--handoff-target TARGET") { |v| buy[:handoff_target] = v }
    end
    private_class_method :add_handoff_options

    # docs/plans/handoff-reconcile.md Phase 3 — `--wait`/`--wait-timeout`
    # land on `parsed`, never on `buy`: they're consumed by
    # `#wait_for_handoff` after `Buy#call` returns, and `Buy.new` has no
    # `wait:`/`wait_timeout:` keyword to accidentally receive them.
    def self.add_wait_options(parser, parsed)
      parser.on("--wait") { parsed[:wait] = true }
      parser.on("--wait-timeout DURATION") { |v| parsed[:wait_timeout] = v }
    end
    private_class_method :add_wait_options

    # `--query` feeds both halves: it's the store search when there's no URL
    # and the catalog search once a store is settled, so it's registered once
    # here rather than twice on the same parser.
    def self.add_search_options(parser, buy, parsed)
      parser.on("--offer REF") { |v| parsed[:offer] = v }
      parser.on("--quote QUOTE_ID") { |v| parsed[:quote] = v }
      parser.on("--query QUERY") { |v| parsed[:find][:query] = buy[:query] = v }
      parser.on("--store URL") { |v| parsed[:store] = v }
      parser.on("--limit N", Integer) { |v| parsed[:find][:limit] = v }
      parser.on("--max-price N", Float) { |v| parsed[:find][:max_price] = buy[:max_price] = to_minor_units(v) }
    end
    private_class_method :add_search_options

    # --- pick / approve (docs/plans/human-pick-and-approve.md Phase 2) ---

    # Outcomes a pick/approve run exits 0 on: an answer, a page shown, or a
    # question handed to the agent. Everything else (cancelled, not found,
    # used, refused, no terminal) exits 1.
    PROMPT_OK_OUTCOMES = %w[picked approved viewed needs_pick needs_approval].freeze

    def self.run_pick(argv)
      opts = parse_prompt_options(argv) do |parser, o|
        parser.on("--search ID") { |v| o[:search] = v }
        parser.on("--choose REF") { |v| o[:choose] = v }
        parser.on("--compare REF") { |v| o[:compare] = v }
        parser.on("--view REF") { |v| o[:view] = v }
      end
      return 1 unless opts

      pick = Pick.new(prompt: HumanPrompt.new(via: opts[:via], json: opts[:json]), comparer: method(:compare_offer),
                      **opts.slice(:search, :choose, :view, :compare))
      print_prompt_result(pick.call, opts[:json])
    end
    private_class_method :run_pick

    def self.run_approve(argv)
      quote_id = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      opts = parse_prompt_options(argv) do |parser, o|
        parser.on("--relayed-yes") { o[:relayed_yes] = true }
        parser.on("--view") { o[:view] = true }
      end
      return 1 unless opts
      return prompt_usage(opts[:json], "portage approve needs a QUOTE_ID.") unless quote_id

      approve = Approve.new(quote_id: quote_id, prompt: HumanPrompt.new(via: opts[:via], json: opts[:json]),
                            **opts.slice(:relayed_yes, :view))
      print_prompt_result(approve.call, opts[:json])
    end
    private_class_method :run_approve

    # `--via`/`--json` for both commands, plus whatever the block adds.
    # @return [Hash, nil] nil on a bad flag (already reported).
    def self.parse_prompt_options(argv)
      opts = { via: "auto" }
      json = argv.include?("--json")
      OptionParser.new do |parser|
        parser.on("--via SURFACE", HumanPrompt::VIAS) { |v| opts[:via] = v }
        parser.on("--json") { opts[:json] = true }
        yield parser, opts
      end.parse!(argv)
      opts
    rescue OptionParser::ParseError => e
      prompt_usage(json, e.message)
      nil
    end
    private_class_method :parse_prompt_options

    def self.prompt_usage(json, message)
      json ? puts(JSON.pretty_generate(outcome: "invalid_option", message: message)) : warn("#{message}\n#{USAGE}")
      1
    end
    private_class_method :prompt_usage

    # Pick's "Compare an offer across stores": the same Compare run
    # `portage compare` does, from the saved offer's store and product.
    def self.compare_offer(offer)
      return { offers: [], message: "Couldn't compare — see the proxy error above." } unless apply_proxy_settings({})

      Compare.new(origin_url: offer["store"], origin_product_id: offer["product_id"]).call
    end
    private_class_method :compare_offer

    def self.print_prompt_result(result, json)
      puts json ? JSON.pretty_generate(result) : format_prompt_result(result)
      PROMPT_OK_OUTCOMES.include?(result[:outcome]) ? 0 : 1
    end
    private_class_method :print_prompt_result

    def self.format_prompt_result(result)
      lines = ["[#{result[:outcome]}] #{result[:message]}"]
      Array(result[:choices]).each_with_index { |choice, index| lines << "  #{index + 1}. #{choice_line(choice)}" }
      lines << "  #{approval_line(result[:summary])}" if result[:summary]
      lines.join("\n")
    end
    private_class_method :format_prompt_result

    def self.choice_line(choice)
      [choice[:label], choice[:url], ("ref #{choice[:ref]}" if choice[:ref])].compact.join(" — ")
    end
    private_class_method :choice_line

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

    # `outcome` first, since it's what the entry is for. Entries recorded
    # before `outcome` existed fall back to their checkout_status/message.
    def self.history_purchase_line(entry)
      items = Array(entry["items"]).map { |item| item_label(item) }.join(", ")
      [
        "#{Time.at(entry['at'])} — #{entry['outcome'] || entry['checkout_status'] || entry['message']}",
        "#{entry['url']} (#{entry['query']})", (items unless items.empty?),
        (format_amount(entry["total"], entry["currency"]) if entry["total"]),
        (entry["checkout_url"] unless entry["outcome"] == "purchased")
      ].compact.join(" — ")
    end
    private_class_method :history_purchase_line

    # Takes a report's symbol-keyed item or a history entry's string-keyed
    # one.
    def self.item_label(item)
      item = item.transform_keys(&:to_s)
      "#{item['title'] || item['id']} x#{item['quantity']}"
    end
    private_class_method :item_label

    def self.history_search_line(entry)
      where = entry["url"] ? " at #{entry['url']}" : ""
      "#{Time.at(entry['at'])} — \"#{entry['query']}\"#{where} — #{entry['offer_count']} result(s)"
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
      opts = { scope_merchants: [], proxy: {} }
      OptionParser.new do |parser|
        parser.on("--label NAME") { |v| opts[:label] = v }
        parser.on("--json") { opts[:json] = true }
        parser.on("--scope-merchant HOST") { |v| opts[:scope_merchants] << v }
        parser.on("--scope-max-amount N", Integer) { |v| opts[:scope_max_amount] = v }
        parser.on("--scope-currency CUR") { |v| opts[:scope_currency] = v }
        ProxySettings.add_options(parser, opts[:proxy])
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
      return 1 unless apply_proxy_settings(opts[:proxy])

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

    # `require_approval` is always shown at its effective value, the
    # default included, so "what does `--yes` need right now" is never a
    # guess.
    def self.run_policy_show(argv)
      json = false
      OptionParser.new { |parser| parser.on("--json") { json = true } }.parse!(argv)
      policy = Portage::Ucp::Policy.load
      effective = policy.to_h.merge(ApprovalPolicy::KEY => ApprovalPolicy.level(policy))
      puts json ? JSON.pretty_generate(effective) : format_policy(policy)
      0
    end
    private_class_method :run_policy_show

    def self.format_policy(policy)
      spending = policy.to_h.except(ApprovalPolicy::KEY)
      body = spending.empty? ? "(no policy configured — every spending check passes)" : JSON.pretty_generate(spending)
      default = " (default)" unless ApprovalPolicy.configured?(policy)
      "#{body}\nrequire_approval: #{ApprovalPolicy.level(policy)}#{default}"
    end
    private_class_method :format_policy

    def self.parse_policy_set_options(argv)
      opts = { allow: [] }
      OptionParser.new do |parser|
        add_policy_cap_options(parser, opts)
        parser.on("--velocity-count N", Integer) { |v| opts[:velocity_count] = v }
        parser.on("--velocity-window-seconds N", Integer) { |v| opts[:velocity_window_seconds] = v }
        parser.on("--allow HOST") { |v| opts[:allow] << v }
        parser.on("--clear-allowlist") { opts[:clear_allowlist] = true }
        parser.on("--require-approval LEVEL", ApprovalPolicy::LEVELS) { |v| opts[:require_approval] = v }
      end.parse!(argv)
      opts
    end
    private_class_method :parse_policy_set_options

    def self.add_policy_cap_options(parser, opts)
      parser.on("--per-transaction-cap N", Integer) { |v| opts[:per_transaction_cap] = v }
      parser.on("--rolling-cap N", Integer) { |v| opts[:rolling_cap] = v }
      parser.on("--rolling-window-seconds N", Integer) { |v| opts[:rolling_window_seconds] = v }
      parser.on("--currency CUR") { |v| opts[:currency] = v }
    end
    private_class_method :add_policy_cap_options

    # Each `--*` group is applied independently and only when its required
    # fields are present — `portage policy set --allow shop.example.com`
    # touches only the allowlist, leaving caps/velocity untouched, so caps
    # and the allowlist can be configured in separate invocations.
    #
    # `--require-approval` goes first: a lowering the person doesn't confirm
    # at the terminal refuses the whole invocation, so nothing else in it
    # changes either.
    def self.run_policy_set(argv)
      opts = parse_policy_set_options(argv)
      policy = Portage::Ucp::Policy.load
      return 1 unless require_approval_applied?(policy, opts[:require_approval])

      set_policy_cap(policy, opts)
      set_policy_velocity(policy, opts)
      set_policy_allowlist(policy, opts)
      puts format_policy(policy)
      0
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n#{USAGE}"
      1
    end
    private_class_method :run_policy_set

    # docs/plans/human-pick-and-approve.md Phase 2: raising the level (or
    # setting the same one) needs nothing; lowering it (person -> any/off,
    # any -> off) needs a yes typed on the tty, since an agent with a shell
    # can run `policy set` but can't type on /dev/tty. No terminal, no
    # change.
    # @return [Boolean] false when a lowering was refused (nothing changed).
    def self.require_approval_applied?(policy, level)
      return true unless level

      current = ApprovalPolicy.level(policy)
      return false if ApprovalPolicy.lowering?(current, level) && !confirm_lowering(current, level)

      policy.set(ApprovalPolicy::KEY, level)
      true
    end
    private_class_method :require_approval_applied?

    def self.confirm_lowering(current, level)
      prompt = HumanPrompt.new(via: "tty")
      return true if prompt.confirm("Lower require_approval from #{current} to #{level}? #{lowering_effect(level)}")

      warn "require_approval left at #{current}."
      false
    rescue HumanPrompt::NoTerminal
      warn "Lowering require_approval (#{current} -> #{level}) needs a yes typed at a terminal, and there's no " \
           "terminal here — nothing changed. Run it yourself from a terminal."
      false
    end
    private_class_method :confirm_lowering

    def self.lowering_effect(level)
      return "`portage buy --yes` would then buy without anyone approving the total." if level == "off"

      "An agent relaying your yes would then be enough to buy."
    end
    private_class_method :lowering_effect

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
      when "handoff_only"
        "#{result[:host]} is hand-off only — there's nothing to set up here. Sign in and add a card " \
        "on #{result[:host]} yourself."
      else "This store doesn't support payment enrollment."
      end
    end
    private_class_method :format_payment_enroll

    # --- orders ---

    # docs/plans/handoff-reconcile.md Phase 1 — resolves every pending
    # `settled_by: "shopper"` TransactionLog record (or just the one named
    # by `--checkout`) by re-fetching that checkout from the store. Safe to
    # run from cron/launchd: a record that's already terminal, or that
    # doesn't belong to this run (a `--checkout` for a different id, or
    # `settled_by: nil` dispatcher crash-evidence), is a no-op result, not
    # an error, so a scheduled run never needs its own filtering logic.
    def self.run_orders(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      return run_orders_reconcile(argv) if sub == "reconcile"

      warn USAGE
      1
    end
    private_class_method :run_orders

    def self.run_orders_reconcile(argv)
      opts = {}
      OptionParser.new do |parser|
        parser.on("--checkout ID") { |v| opts[:checkout] = v }
        parser.on("--json") { opts[:json] = true }
      end.parse!(argv)

      transaction_log = Portage::Ucp::Support::TransactionLog.new
      reconciler = HandoffReconciler.new(transaction_log: transaction_log)
      results = reconcile_records(opts[:checkout], transaction_log, reconciler)

      puts opts[:json] ? JSON.pretty_generate(results.map(&:to_h)) : format_reconcile(results)
      0
    end
    private_class_method :run_orders_reconcile

    def self.reconcile_records(checkout_id, transaction_log, reconciler)
      return reconcile_one_checkout(checkout_id, transaction_log, reconciler) if checkout_id

      HandoffReconciler.each_pending_shopper_record(transaction_log).map { |record| reconciler.call(record) }
    end
    private_class_method :reconcile_records

    # `--checkout ID` reconciles the one named record whatever its
    # `settled_by`/status — #call itself still refuses to settle anything
    # that isn't a pending shopper record, this just skips the "iterate
    # every pending record" step when the caller already knows which one.
    def self.reconcile_one_checkout(checkout_id, transaction_log, reconciler)
      key = transaction_log.each_record.find { |r| r["checkout_id"] == checkout_id }&.fetch("idempotency_key", nil)
      return [] unless key

      [reconciler.call(transaction_log.find(key))]
    end
    private_class_method :reconcile_one_checkout

    def self.format_reconcile(results)
      return "(nothing to reconcile)" if results.empty?

      results.map { |r| format_reconcile_result(r) }.join("\n")
    end
    private_class_method :format_reconcile

    def self.format_reconcile_result(result)
      return "#{result.idempotency_key}: #{result.note}" unless result.settled

      parts = ["#{result.idempotency_key}: #{result.status}"]
      parts << "resolution: #{result.resolution}" if result.resolution
      parts << "order: #{result.order_id}" if result.order_id
      parts << format_amount(result.amount, result.currency) if result.amount
      parts.join(" — ")
    end
    private_class_method :format_reconcile_result

    # --- index (docs/plans/buy-skill-and-local-browser.md Phase 2b) ---

    INDEX_SUBCOMMANDS = {
      "build" => ->(argv) { run_index_build(argv, refresh: false) },
      "refresh" => ->(argv) { run_index_build(argv, refresh: true) },
      "show" => ->(argv) { run_index_show(argv) },
      "add" => ->(argv) { run_index_add(argv) },
      "remove" => ->(argv) { run_index_remove(argv) },
      "sources" => ->(argv) { run_index_sources(argv) }
    }.freeze

    def self.run_index(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      return INDEX_SUBCOMMANDS[sub].call(argv) if INDEX_SUBCOMMANDS.key?(sub)

      warn USAGE
      1
    end
    private_class_method :run_index

    def self.parse_index_build_options(argv)
      opts = { sources: nil, queries: nil, dry_run: false, json: false, export: nil }
      OptionParser.new do |parser|
        parser.on("--sources LIST") { |v| opts[:sources] = v.split(",").map(&:strip) }
        parser.on("--queries FILE") { |v| opts[:queries] = v }
        parser.on("--dry-run") { opts[:dry_run] = true }
        parser.on("--export DIR") { |v| opts[:export] = v }
        parser.on("--json") { opts[:json] = true }
      end.parse!(argv)
      opts[:queries] &&= File.readlines(opts[:queries]).map(&:strip).reject(&:empty?)
      opts
    end
    private_class_method :parse_index_build_options

    def self.run_index_build(argv, refresh:)
      opts = parse_index_build_options(argv)
      builder = Index::Builder.new(sources: index_sources(opts[:sources]), out: opts[:json] ? nil : $stdout)
      result = if refresh
                 builder.refresh(queries: opts[:queries], dry_run: opts[:dry_run], export: opts[:export])
               else
                 builder.build(queries: opts[:queries], dry_run: opts[:dry_run], export: opts[:export])
               end
      puts opts[:json] ? JSON.pretty_generate(result) : format_index_build(result)
      0
    end
    private_class_method :run_index_build

    def self.index_sources(names) = names ? Index::Sources.by_name(names) : nil
    private_class_method :index_sources

    def self.format_index_build(result)
      lines = ["Ran #{result[:sources_run].join(', ')} — #{result[:candidates]} candidate(s)."]
      lines << "Checked #{result[:new_origins_checked].length} new origin(s), " \
               "#{result[:verified].length} verified UCP."
      lines << "Hit the #{Index::Builder::MAX_NEW_PROBES}-probe cap for this run." if result[:capped]
      lines << "#{result[:products_added]} product sighting(s) recorded." if result[:products_added]
      if result[:exported]
        lines << "Exported #{result[:exported][:stores]} store(s), #{result[:exported][:products]} " \
                 "product(s) to #{result[:exported][:dir]}."
      end
      lines.join("\n")
    end
    private_class_method :format_index_build

    def self.run_index_show(argv)
      opts = { kind: nil, json: false }
      OptionParser.new do |parser|
        parser.on("--stores") { opts[:kind] = "stores" }
        parser.on("--products") { opts[:kind] = "products" }
        parser.on("--json") { opts[:json] = true }
      end.parse!(argv)

      result = { stores: opts[:kind] == "products" ? [] : Index::Store.new.all,
                 products: opts[:kind] == "stores" ? [] : Index::ProductStore.new.all }
      puts opts[:json] ? JSON.pretty_generate(result) : format_index_show(result)
      0
    end
    private_class_method :run_index_show

    def self.format_index_show(result)
      lines = ["Stores:"]
      result[:stores].each { |s| lines << "  #{s['origin']} (#{Array(s['sources']).join(', ')})" }
      lines << "(none)" if result[:stores].empty?
      lines << "Products:"
      result[:products].each { |p| lines << "  #{p['title'] || p['key']}" }
      lines << "(none)" if result[:products].empty?
      lines.join("\n")
    end
    private_class_method :format_index_show

    def self.run_index_add(argv)
      json = argv.delete("--json") ? true : false
      url = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      unless url
        warn USAGE
        return 1
      end

      result = Index::Builder.new.add(url)
      puts json ? JSON.pretty_generate(result) : result[:message]
      result[:added] ? 0 : 1
    end
    private_class_method :run_index_add

    def self.run_index_remove(argv)
      json = argv.delete("--json") ? true : false
      host = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      unless host
        warn USAGE
        return 1
      end

      result = Index::Builder.new.remove(host)
      puts json ? JSON.pretty_generate(result) : result[:message]
      result[:removed] ? 0 : 1
    end
    private_class_method :run_index_remove

    def self.run_index_sources(argv)
      json = argv.delete("--json") ? true : false
      sources = Index::Sources.all.map { |s| { name: s.name, description: s.description, path: s.source_path } }
      puts json ? JSON.pretty_generate(sources) : format_index_sources(sources)
      0
    end
    private_class_method :run_index_sources

    def self.format_index_sources(sources)
      sources.map { |s| "#{s[:name]}: #{s[:description]}#{" (#{s[:path]})" if s[:path]}" }.join("\n")
    end
    private_class_method :format_index_sources

    # --- browser (docs/plans/buy-skill-and-local-browser.md Phase 3) ---

    BROWSER_SUBCOMMANDS = { "import" => ->(argv) { run_browser_import(argv) },
                            "profile" => ->(argv) { run_browser_profile(argv) } }.freeze

    def self.run_browser(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      return BROWSER_SUBCOMMANDS[sub].call(argv) if BROWSER_SUBCOMMANDS.key?(sub)

      warn USAGE
      1
    end
    private_class_method :run_browser

    def self.parse_browser_import_options(argv)
      opts = { browser: nil, root: nil, history_days: BrowserImport::Importer::DEFAULT_HISTORY_DAYS,
               include_product_pages: false, max_probes: BrowserImport::Importer::MAX_PROBES, exclude: [],
               dry_run: false, yes: false, json: false }
      browser_import_option_parser(opts).parse!(argv)
      opts
    end
    private_class_method :parse_browser_import_options

    def self.browser_import_option_parser(opts)
      OptionParser.new do |parser|
        parser.on("--browser NAME", BrowserImport::Profiles::BROWSERS) { |v| opts[:browser] = v }
        parser.on("--profile-root DIR") { |v| opts[:root] = File.expand_path(v) }
        parser.on("--history-days N", Integer) { |v| opts[:history_days] = v }
        parser.on("--max-probes N", Integer) { |v| opts[:max_probes] = v }
        parser.on("--exclude HOSTS", Array) { |v| opts[:exclude] = v.map(&:strip) }
        %i[include_product_pages dry_run yes json].each do |flag|
          parser.on("--#{flag.to_s.tr('_', '-')}") { opts[flag] = true }
        end
      end
    end
    private_class_method :browser_import_option_parser

    # Reads, reduces and probes (BrowserImport::Importer#plan), shows the
    # list, and saves only through BrowserImport::Confirm's gate: `--yes`,
    # or a "y" at a real TTY prompt. Under `--json`/no TTY without `--yes`
    # nothing is written — the report says `saved: false,
    # needs_confirmation: true` and exits 0, so an agent shows the user the
    # list and re-runs with `--yes` only once they've approved it.
    def self.run_browser_import(argv)
      opts = parse_browser_import_options(argv)
      plan = browser_importer.plan(browser_import_options(opts))
      return report_browser_import(plan, opts, nil) if plan[:error]

      puts format_browser_import(plan) unless opts[:json]
      interactive = !opts[:json] && $stdin.tty?
      decision = BrowserImport::Confirm.new(interactive: interactive).call(plan, yes: opts[:yes],
                                                                                 dry_run: opts[:dry_run])
      saved = decision == :save ? browser_importer.save(plan) : nil
      report_browser_import(plan, opts, decision, saved)
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n#{USAGE}"
      1
    end
    private_class_method :run_browser_import

    # The real HandoffOnly list (docs/plans/buy-skill-and-local-browser.md
    # Phase 5) into Importer's own injectable `handoff_only_hosts:` seam
    # (Phase 3 left it defaulting to `[]` for exactly this) — a history/
    # bookmark domain on the list is kept as `handoff_only: true` and never
    # probed.
    def self.browser_importer
      BrowserImport::Importer.new(handoff_only_hosts: HandoffOnly.new.hosts)
    end
    private_class_method :browser_importer

    def self.browser_import_options(opts)
      browser = opts[:browser] || BrowserImport::Profiles.detect || "chrome"
      BrowserImport::Importer::Options.new(
        browser: browser, root: opts[:root] || BrowserImport::Profiles.default_root(browser),
        history_days: opts[:history_days], include_product_pages: opts[:include_product_pages],
        max_probes: opts[:max_probes], exclude: opts[:exclude]
      )
    end
    private_class_method :browser_import_options

    BROWSER_IMPORT_MESSAGES = {
      dry_run: "Dry run — nothing saved.",
      nothing: "No shop domains to save.",
      declined: "Nothing saved.",
      needs_confirmation: "Nothing saved: there's no terminal to confirm on. Show this list to the user, then " \
                          "re-run with --yes once they've approved it (--exclude HOST,... drops any they don't want)."
    }.freeze

    def self.report_browser_import(plan, opts, decision, saved = nil)
      message = plan[:message] || browser_import_message(decision, saved)
      if opts[:json]
        puts JSON.pretty_generate(plan.merge(saved: !saved.nil?, needs_confirmation: decision == :needs_confirmation,
                                             message: message))
      else
        puts message
      end
      plan[:error] ? 1 : 0
    end
    private_class_method :report_browser_import

    def self.browser_import_message(decision, saved)
      return "Saved #{saved[:stores]} store(s) and #{saved[:products]} product(s) to your local index." if saved

      BROWSER_IMPORT_MESSAGES.fetch(decision, "Nothing saved.")
    end
    private_class_method :browser_import_message

    def self.format_browser_import(plan)
      lines = browser_import_counts(plan)
      lines << "Shops found (#{plan[:kept].length}):"
      plan[:kept].each { |entry| lines << "  #{browser_import_line(entry)}" }
      lines << "  (none)" if plan[:kept].empty?
      lines << "#{plan[:products].length} product page(s) to keep." if plan[:products].any?
      lines.join("\n")
    end
    private_class_method :format_browser_import

    def self.browser_import_counts(plan)
      skipped = plan[:skipped].map { |reason, n| "#{n} #{reason}" }.join(", ")
      lines = ["Read #{plan[:rows][:history]} history and #{plan[:rows][:bookmark]} bookmark row(s) across " \
               "#{plan[:domains]} domain(s) from #{plan[:browser]}.",
               "Skipped #{skipped.empty? ? 'none' : skipped}; probed #{plan[:probed]} " \
               "(#{plan[:not_ucp]} without UCP, #{plan[:cached_miss]} already known not to)."]
      lines << "Hit the #{plan[:probed]}-probe cap; #{plan[:unprobed]} domain(s) left unprobed." if plan[:capped]
      lines
    end
    private_class_method :browser_import_counts

    def self.browser_import_line(entry)
      categories = entry[:category_names].empty? ? "uncategorised" : entry[:category_names].join(", ")
      "#{entry[:domain]} — #{entry[:verdict]} — #{categories} " \
        "(#{entry[:sources].join(', ')}, #{entry[:visits]} visit(s))"
    end
    private_class_method :browser_import_line

    # --- browser profile (docs/plans/buy-skill-and-local-browser.md Phase 6) ---

    BROWSER_PROFILE_SUBCOMMANDS = {
      "init" => ->(argv) { run_browser_profile_init(argv) },
      "open" => ->(argv) { run_browser_profile_open(argv) },
      "status" => ->(argv) { run_browser_profile_status(argv) }
    }.freeze

    def self.run_browser_profile(argv)
      sub = argv.first && !argv.first.start_with?("-") ? argv.shift : nil
      return browser_profile_usage unless BROWSER_PROFILE_SUBCOMMANDS.key?(sub)

      BROWSER_PROFILE_SUBCOMMANDS[sub].call(argv)
    end
    private_class_method :run_browser_profile

    def self.browser_profile_usage
      warn USAGE
      1
    end
    private_class_method :browser_profile_usage

    def self.parse_browser_profile_options(argv)
      opts = { browser: nil, port: BrowserProfile::Profile::DEFAULT_PORT, url: nil, json: false }
      OptionParser.new do |parser|
        parser.on("--browser NAME", BrowserProfile::Browsers::CHROMIUM) { |v| opts[:browser] = v }
        parser.on("--port N", Integer) { |v| opts[:port] = v }
        parser.on("--url URL") { |v| opts[:url] = v }
        parser.on("--json") { opts[:json] = true }
      end.parse!(argv)
      opts
    end
    private_class_method :parse_browser_profile_options

    # `--browser` names the exact browser; without it, the first Chromium
    # family browser BrowserImport::Profiles finds installed, falling back
    # to "chrome" — same "pick something reasonable, let --browser
    # override" posture as run_browser_import's own default.
    def self.browser_profile_for(opts)
      browser = opts[:browser] || BrowserProfile::Browsers.detect || "chrome"
      BrowserProfile::Profile.new(browser: browser, port: opts[:port])
    end
    private_class_method :browser_profile_for

    def self.run_browser_profile_init(argv)
      opts = parse_browser_profile_options(argv)
      result = browser_profile_for(opts).init!
      puts opts[:json] ? JSON.pretty_generate(result) : "Profile ready at #{result[:dir]} (#{result[:browser]})."
      0
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n#{USAGE}"
      1
    end
    private_class_method :run_browser_profile_init

    # Launches the profile (if it isn't already running on its own port)
    # and either opens a new tab at --url or attaches to the first
    # existing one. Never touches the browser's default profile — Profile
    # itself only ever points --user-data-dir at its own dedicated
    # directory.
    def self.run_browser_profile_open(argv)
      opts = parse_browser_profile_options(argv)
      result = browser_profile_for(opts).open!(url: opts[:url])
      puts opts[:json] ? JSON.pretty_generate(result) : format_browser_profile_open(result)
      0
    rescue BrowserProfile::Error => e
      report_browser_profile_error(e, opts[:json])
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n#{USAGE}"
      1
    end
    private_class_method :run_browser_profile_open

    def self.run_browser_profile_status(argv)
      opts = parse_browser_profile_options(argv)
      result = browser_profile_for(opts).status
      puts opts[:json] ? JSON.pretty_generate(result) : format_browser_profile_status(result)
      0
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n#{USAGE}"
      1
    end
    private_class_method :run_browser_profile_status

    def self.format_browser_profile_open(result)
      tab = result.dig(:target, "url")
      "#{result[:browser]} profile is open (port #{result[:port]}, #{result[:dir]})#{" — tab: #{tab}" if tab}."
    end
    private_class_method :format_browser_profile_open

    def self.format_browser_profile_status(result)
      return "#{result[:browser]} profile (#{result[:dir]}) isn't running." unless result[:running]

      "#{result[:browser]} profile is running on port #{result[:port]} (#{result[:dir]})."
    end
    private_class_method :format_browser_profile_status

    def self.report_browser_profile_error(error, json)
      if json
        puts JSON.pretty_generate(error: error.class.name.split("::").last, message: error.message)
      else
        warn error.message
      end
      1
    end
    private_class_method :report_browser_profile_error

    # --- doctor ---

    def self.parse_doctor_options(argv)
      opts = { proxy: {} }
      OptionParser.new do |parser|
        parser.on("--require FILE") { |v| opts[:require] = v }
        parser.on("--adapter CLASS_NAME") { |v| opts[:adapter] = v }
        parser.on("--json") { opts[:json] = true }
        ProxySettings.add_options(parser, opts[:proxy])
      end.parse!(argv)
      opts
    end
    private_class_method :parse_doctor_options

    # `wizard: :force` is `portage setup`, always offering the wizard on a
    # TTY; `:auto` is `doctor`/`configure`, which only offers it when
    # Doctor#nothing_configured? — the read-only report is what every other
    # run of `doctor` still gets, exactly as before this phase
    # (docs/plans/buy-skill-and-local-browser.md Phase 4).
    def self.run_doctor(argv, wizard: :auto)
      opts = parse_doctor_options(argv)
      require File.expand_path(opts[:require]) if opts[:require]
      adapter_class = opts[:adapter] && Object.const_get(opts[:adapter])
      proxy_settings = apply_proxy_settings(opts[:proxy])
      return 1 unless proxy_settings

      doctor = Doctor.new(adapter_class: adapter_class, proxy_settings: proxy_settings,
                          seller: !(opts[:require] || opts[:adapter]).nil?)
      return run_setup_wizard if run_wizard?(wizard, opts, doctor)

      report_doctor(doctor.call, json: opts[:json])
    end
    private_class_method :run_doctor

    def self.run_setup(argv) = run_doctor(argv, wizard: :force)
    private_class_method :run_setup

    # --json or no TTY on stdin always stays today's read-only report,
    # whichever command name was used — a piped/CI/agent run never blocks
    # on a prompt it can't answer.
    def self.run_wizard?(mode, opts, doctor)
      return false if opts[:json] || !$stdin.tty?
      return true if mode == :force

      doctor.nothing_configured?
    end
    private_class_method :run_wizard?

    def self.run_setup_wizard
      SetupWizard.new.call
    end
    private_class_method :run_setup_wizard

    def self.report_doctor(findings, json:)
      puts json ? JSON.pretty_generate(findings.map(&:to_h)) : format_doctor(findings)
      findings.none?(&:warning?) ? 0 : 1
    end
    private_class_method :report_doctor

    # Info findings (install method, Ruby, adapters, PATH) first, then the
    # warnings, which alone decide the exit code.
    def self.format_doctor(findings)
      info, warnings = findings.partition { |f| !f.warning? }
      lines = info.map { |f| "[#{f.check}] #{f.message}" }
      lines << "" unless info.empty?
      lines.concat(warnings.empty? ? ["No issues found."] : warnings.map { |f| "[#{f.check}] #{f.message}" })
      lines.join("\n")
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
      puts "Next: commit #{result[:profile_path]}, then, once it's on main, run " \
           "`bundle exec rake agent_profile:purge` from the repo root — see docs/agent-profile.md."
      0
    end
    private_class_method :run_generate_agent_profile

    # --- output ---

    # The `[outcome]` tag leads so a caller reading text, not --json, has the
    # same value to branch on that the JSON report carries.
    def self.format_report(report)
      lines = ["[#{report[:outcome]}] #{report[:message]} (source: #{report[:source]})"]
      report[:products].each { |p| lines << "  - #{product_line(p)}" }
      lines.concat(format_checkout(report))
      lines.concat(format_quote(report))
      lines << "  checkout: #{report[:checkout_url]}" if report[:checkout_url]
      lines.concat(format_handoff(report[:handoff])) if report[:handoff]
      lines.concat(format_decisions(report[:decisions])) if report[:decisions]&.any?
      lines.join("\n")
    end
    private_class_method :format_report

    def self.format_quote(report)
      lines = report[:quote_id] ? ["  quote: #{report[:quote_id]}"] : []
      lines << "  approve: #{approval_line(report[:summary])}" if report[:summary]
      lines
    end
    private_class_method :format_quote

    def self.approval_line(summary)
      [Approve.describe(summary), summary[:url]].compact.join(" — ")
    end
    private_class_method :approval_line

    # What the checkout holds, as opposed to the search results above it,
    # and where it differs from the request.
    def self.format_checkout(report)
      lines = Array(report[:items]).map { |item| "  in checkout: #{item_label(item)}" }
      total = report_total(report)
      lines << "  total: #{format_amount(total, report[:currency])}" if total
      lines + Array(report[:warnings]).map { |w| "  warning: #{w}" }
    end
    private_class_method :format_checkout

    def self.format_decisions(decisions)
      decisions.map do |name, verdict|
        "  decision #{name}: #{verdict.compact.map { |key, value| "#{key}=#{value}" }.join(' ')}"
      end
    end
    private_class_method :format_decisions

    def self.format_handoff(handoff)
      lines = ["  opened in browser: #{handoff[:opened]}", "  notified: #{handoff[:notified]}"]
      lines << "  notify error: #{handoff[:notify_error]}" if handoff[:notify_error]
      lines
    end
    private_class_method :format_handoff

    def self.product_line(product)
      product.respond_to?(:title) ? "#{product.id}: #{product.title}" : "#{product['id']}: #{product['title']}"
    end
    private_class_method :product_line

    def self.format_find(report)
      lines = [report[:message].to_s]
      report[:offers].each_with_index { |offer, index| lines << "  #{index + 1}. #{offer_line(offer)}" }
      lines << "  search: #{report[:search_id]} (portage pick --search #{report[:search_id]})" if report[:search_id]
      lines.join("\n")
    end
    private_class_method :format_find

    def self.offer_line(offer)
      parts = ["#{offer[:store]} — #{offer[:title]} (#{offer[:product_id]})", format_price(offer)]
      parts << "browse only" unless offer[:checkout]
      parts << "ref #{offer[:offer_ref]}" if offer[:offer_ref]
      parts.join(" — ")
    end
    private_class_method :offer_line

    def self.format_compare(report)
      lines = [report[:message].to_s]
      report[:offers].each_with_index { |offer, index| lines << "  #{index + 1}. #{compare_offer_line(offer)}" }
      lines << "  search: #{report[:search_id]} (portage pick --search #{report[:search_id]})" if report[:search_id]
      lines.join("\n")
    end
    private_class_method :format_compare

    def self.compare_offer_line(offer)
      parts = ["[#{offer[:match]}] #{offer[:store]} — #{offer[:title]} (#{offer[:product_id]})", format_price(offer)]
      parts << "browse only" unless offer[:checkout]
      parts << "ref #{offer[:offer_ref]}" if offer[:offer_ref]
      parts.join(" — ")
    end
    private_class_method :compare_offer_line

    def self.format_price(offer)
      return "price n/a" unless offer[:amount]

      format_amount(offer[:amount], offer[:currency])
    end
    private_class_method :format_price

    def self.format_amount(amount, currency) = Money.format_amount(amount, currency)
    private_class_method :format_amount
  end
end

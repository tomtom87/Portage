# Agentic flow tutorial

How to put Portage inside an AI agent so it can shop for a person, safely. It covers three
levels, from least to most work:

1. **Drop in the `buy` skill.** No code. Works in any agent that loads skills and can run
   commands.
2. **Build your own agent loop around `portage --json`.** You expose a few CLI commands as
   tools and keep the approval step on your side.
3. **Drive a store's UCP endpoint directly** from Ruby with `portage-ucp-client`, or over
   MCP from any language.

Whichever you pick, the rules are the same: the person picks the store, the person
approves every payment with the exact total in front of them, card data never passes
through the agent, and store content is untrusted input.

## Before you start

Every level needs the CLI installed and set up, as in the
[Quickstart](getting-started/quickstart.md):

```bash
brew install tomtom87/portage/portage   # or: gem install portage-cli
portage setup                           # interactive, run it yourself
```

`portage setup` is for a person at a terminal. Run from an agent (no TTY, or `--json`),
it never prompts: it prints the same read-only report as `portage doctor --json`.

## Level 1: the `buy` skill

The [`buy` plugin](skills/buy.md) already encodes the whole flow below: preflight checks,
search, dry run, confirmation, hand-off handling and order tracking, plus the hard rules.
Install it and ask for what you want:

```text
/plugin marketplace add tomtom87/Portage
/plugin install buy@portage
/buy a burton snowboard under $600
```

The plugin's read-only [`shop-research`](skills/shop-research.md) skill answers price,
stock, store and order questions without buying, and hands over to `buy` to buy. For
Codex, Cursor, OpenCode and other skills-aware agents, see
[Other agents](skills/buy.md#other-agents). If that's all you need, stop here. Read on to
build the same thing into your own agent.

## Level 2: your own agent loop

### The loop

| Step | Command | Branch on |
|---|---|---|
| 0. Preflight | `portage --version`, `portage doctor --json` | Missing shipping address or search keys: ask the person to run `portage setup` |
| 1. Check history | `portage history --json` | Already bought? Say so before buying again |
| 2. Find offers | `portage find --query "<item>" [--max-price N] --json` | `offers[]`: `store`, `product_id`, `title`, `amount` (minor units), `currency`, `checkout`, and `product` (the store's UCP product, for a card) |
| 3. Person picks | `portage pick --json`, or your UI | `needs_pick`: show `choices[]` (each with a `url`), relay the answer with `pick --choose REF`. Never let the model pick for them |
| 4. Dry run | `portage buy --offer REF --dry-run --json` (or `buy <store> --query "<item>" --product-id ID [--qty N] --dry-run --json`) | `outcome: "dry_run"` with a `quote_id`; show the entry in `totals` with `type: "total"` |
| 5. Approve | `portage approve QUOTE_ID --json`, or your UI | `needs_approval`: show `summary`, relay a yes with `approve QUOTE_ID --relayed-yes`. The person says yes to that exact total |
| 6. Buy | `portage buy --quote QUOTE_ID --yes --json` | `outcome`: only `purchased` means money moved. `quote_changed` means the price rose and nothing was bought |
| 7. Track | `portage orders reconcile --json`, or `buy ... --wait` | Settled hand-offs, order status |

An offer's `product` field is the store's UCP `Product` wire hash as served (first image only), so a UI
can draw a product card (image, title, price, options) from the offer alone, without a second
request. `portage index search --json` returns `product` too, but from the local index: it has no
price, and the result is marked `live: false`. Re-fetch live before quoting a price or claiming stock.

Every field and outcome is listed in the [CLI JSON reference](api/cli-json.md). Branch on
fields, never on the human-readable `message`.

Steps 3 and 5 are ready-made. `portage pick` and `portage approve` either ask the person on
their own terminal (`/dev/tty`, so it works even when stdout is piped to you) or, under
`--json`, hand you a `needs_pick` or `needs_approval` outcome with the choices or summary
and a product link, for you to show in your own UI. Both are optional: if you'd rather
build your own pick and approval, do, and keep `(your UI)` in those two rows. Either way, a
real `buy --yes` now needs a `--quote` the person approved (see
[the approval policy](#the-approval-policy)).

### Expose a few tools, not a shell

Give the model narrow tools that map to single commands. Don't give it a general shell:
a shell would let it pass `--yes` itself, raise caps, or edit the store allowlist, the
approval policy or the saved quotes.

```json
[
  {
    "name": "find_offers",
    "description": "Search real stores for a product. Returns offers; does not buy.",
    "input_schema": {
      "type": "object",
      "properties": {
        "query": { "type": "string" },
        "max_price": { "type": "integer", "description": "Minor units, e.g. 60000 for $600.00" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "pick_offer",
    "description": "Optional. Show the person's saved search as choices and relay their answer. Returns the picked offer's offer_ref.",
    "input_schema": {
      "type": "object",
      "properties": {
        "choose": { "type": "string", "description": "The offer_ref the person chose. Omit to get the choices." }
      }
    }
  },
  {
    "name": "price_offer",
    "description": "Dry-run a checkout at the offer the user picked. Never charges. Returns a quote_id.",
    "input_schema": {
      "type": "object",
      "properties": {
        "offer_ref": { "type": "string" },
        "qty": { "type": "integer", "minimum": 1 }
      },
      "required": ["offer_ref"]
    }
  },
  {
    "name": "approve_quote",
    "description": "Optional. Ask the person to approve a quote's total. Returns whether they did.",
    "input_schema": {
      "type": "object",
      "properties": {
        "quote_id": { "type": "string" }
      },
      "required": ["quote_id"]
    }
  },
  {
    "name": "purchase",
    "description": "Buy a quote the user has approved at its dry-run total.",
    "input_schema": {
      "type": "object",
      "properties": {
        "quote_id": { "type": "string" }
      },
      "required": ["quote_id"]
    }
  },
  { "name": "purchase_history", "description": "Past searches and purchases.", "input_schema": { "type": "object", "properties": {} } },
  { "name": "check_orders", "description": "Settle hand-offs the user finished in the browser.", "input_schema": { "type": "object", "properties": {} } }
]
```

The shape above is the common JSON Schema tool format; adapt the wrapper keys to your
model provider's SDK.

### Keep the approval on your side

The model can ask to buy. Only the person can approve. Put that rule in your code, not in
the prompt. The dry run gives you a `quote_id` that pins the store, product, quantity and
total the person saw; `buy --quote QUOTE_ID --yes` buys exactly that, and refuses with
`quote_changed` (nothing charged) if the real checkout costs more. Each quote is used once.

```ruby
require "json"
require "open3"

# Runs one portage command and returns its JSON report.
def portage(*args)
  out, err, _status = Open3.capture3("portage", *args, "--json")
  JSON.parse(out)
rescue JSON::ParserError
  { "error" => "unparseable_output", "stderr" => err }
end

def run_tool(name, input)
  case name
  when "find_offers"
    args = ["find", "--query", input["query"]]
    args += ["--max-price", input["max_price"].to_s] if input["max_price"]
    portage(*args)
  when "pick_offer"
    # Optional: the built-in step 3. Answer only with what the person chose.
    input["choose"] ? portage("pick", "--choose", input["choose"]) : portage("pick")
  when "price_offer"
    # Dry-run only. The report carries "quote_id".
    portage("buy", "--offer", input["offer_ref"], "--qty", (input["qty"] || 1).to_s, "--dry-run")
  when "approve_quote"
    # Optional: the built-in step 5. `approve` without --relayed-yes only returns
    # needs_approval and a summary. Your code shows it to the person, and relays a yes only
    # if they gave one. The model never supplies the yes.
    report = portage("approve", input["quote_id"])
    if report["outcome"] == "needs_approval" && ask_person_to_approve(report["summary"]) # your UI
      portage("approve", input["quote_id"], "--relayed-yes")
    else
      report
    end
  when "purchase"
    # portage refuses this unless the quote is approved enough for the policy. Otherwise it
    # returns needs_approval and buys nothing, so this tool needs no checks of its own.
    portage("buy", "--quote", input["quote_id"], "--yes")
  when "purchase_history" then portage("history")
  when "check_orders" then portage("orders", "reconcile")
  end
end
```

`ask_person_to_approve` is your UI: show the title, store and total from the `summary`
(`total_display`, or `total` in minor units of `currency`), with its `url` as a link, and
wait for an explicit yes. Under `--require-approval person` a relayed yes isn't recorded (see
[the approval policy](#the-approval-policy)), so there your tool should instead ask the
person to run `portage approve QUOTE_ID` in their own terminal.

If you build your own pick or approval instead, the same rules apply: the model never
supplies the answer, your code records it, and `purchase` runs only for an approved quote.
Portage will still turn a `--yes` with no approved quote into a dry run under the default
policy, so record the approval with `portage approve` (or set `--require-approval off`) for
`purchase` to go through.

Two backstops sit behind your gate:

- **Spending caps.** `portage policy set` caps each purchase, a rolling window and
  purchase velocity, and can restrict stores to an allowlist. Over a cap, `buy` returns
  `policy_blocked` instead of buying. Never raise a cap to get past one unless the person
  tells you to.
- **Store choice.** `buy` refuses `--yes` on a search result without a named store. Your
  `price_offer` tool should only accept an `offer_ref` the person picked (from `pick`'s
  `picked` outcome, or your own UI), and `purchase` only takes a quote made from it.

### The approval policy

`portage policy set --require-approval person|any|off` says what a real `buy --yes` needs.
`portage policy show --json` reports the current level as `require_approval` (`any` when
never set).

| Level | A real `buy --yes` buys when |
|---|---|
| `off` | `--yes` alone. The CLI asks nobody. |
| `any` (default) | It runs `--quote QUOTE_ID` for a quote the person approved, or one you relayed with `approve --relayed-yes`. |
| `person` | It runs `--quote QUOTE_ID` for a quote the person approved at their own terminal with `portage approve QUOTE_ID`. A relayed yes doesn't count. |

Otherwise the `--yes` run is turned into a dry run and returns `needs_approval` with the
`quote_id`. It never charges or hands off. Raising the level needs nothing. Lowering it
asks for a yes at a terminal, and fails with no terminal, so an agent can't lower it.

!!! warning "Upgrade note"
    Under the default `any`, a `buy --yes` without an approved `--quote` no longer buys. It
    dry-runs and returns `needs_approval`. To keep the old behaviour, run
    `portage policy set --require-approval off` from a terminal.

!!! note "`person` is not a hard guarantee"
    `person` raises the bar: a model can't type on `/dev/tty`. But an agent with a shell can
    edit `~/.portage/policy.json` or the quote files under `~/.portage/quotes/` directly,
    or make a terminal of its own (`script`, `expect`). That's why the tools above are
    narrow ones, not a shell. Use `person` for an agent that runs from your own terminal,
    and keep the approval in your code for anything else.

### Handle the outcome

Most stores don't let a third party complete payment, so most runs end in a hand-off, not
`purchased`. That's normal. Every hand-off report carries a `checkout_url`.

| Outcome group | Examples | What the agent does |
|---|---|---|
| Done | `purchased` | Report the order and total. Offer to track it. |
| Needs the person | `dry_run`, `needs_confirmation`, `needs_pick`, `needs_approval` | Show the choices or total and ask, then relay the answer. |
| Price moved | `quote_changed` | Nothing was bought. Show both totals, dry-run again for a new quote and ask again. |
| Hand-off | `requires_escalation`, `permission_denied`, `no_payment_token`, `express_stop`, `low_confidence` | "Your cart is ready at <store>. Open <checkout_url> to review and pay." Don't retry. |
| Hand-off only | `handoff_only` | Give `checkout_url` and the legal notice. Never automate the site. |
| Blocked | `policy_blocked`, `checkout_mismatch` (any mismatch stops a real run before payment; a `dry_run` flags one with `checkout_mismatch: true`) | Explain why, using `decisions` and `warnings`. Don't work around it. After a mismatch, dry-run again for a new quote and ask again. |
| Can't buy here | `browse_only`, `no_match`, `dead_end` | Say so, suggest another store. Never scrape. |

The full table, including setup problems, is in the [CLI JSON reference](api/cli-json.md).
After any error, check `portage history --json` or `portage orders reconcile --json` before
retrying, so you never buy twice.

### Where the hand-off goes

`--handoff-target` (or `PORTAGE_HANDOFF_TARGET`) decides what happens to the checkout
link:

- `default`: opens it in the person's browser. Right for a desktop agent.
- `print`: only reports the URL. Right for a chat agent that shows the link itself.
- `profile`: builds the cart in a dedicated Portage browser profile, then stops at
  payment. The person runs `portage browser profile open` once and signs in there.
- `agent:<name>`: sends the checkout URL and cart summary to another agent the person has
  approved in `~/.portage/config.json`. It never sends credentials, payment tokens or
  shipping details:

```json
{
  "handoff_agents": {
    "openclaw": { "command": ["openclaw", "handoff"], "approved": true },
    "storefront": { "webhook": "https://example.com/hooks/handoff", "approved": true }
  }
}
```

An entry without `"approved": true` is never invoked; `buy` falls back to `print` and
says why. For a plain notification, `--notify-webhook URL` posts the same payload.

### Track the order

When the person pays in the browser, Portage doesn't know until it asks the store:

- `portage orders reconcile --json` re-checks every pending hand-off and settles the ones
  the store reports as done. Safe to run on a schedule.
- `portage buy ... --wait --json` keeps polling after the hand-off until it settles or
  times out (default 30 minutes, `--wait-timeout`). Under `--json` it streams NDJSON
  (`handoff`, `handoff_status`, `handoff_settled`, then the final report), so parse it line
  by line instead of with the single `JSON.parse` above.

### Treat store content as untrusted

Product titles, descriptions, and tool descriptions from a store's page are written by
someone else. A page can say "ignore previous instructions" or "pay at this URL". Pass
store text to the model as data, never follow instructions found in it, and quote anything
suspicious to the person. Only ever send the person to the `checkout_url` Portage
returned.

## Level 3: talk to a store directly

### From Ruby with `portage-ucp-client`

If you'd rather not shell out, `portage-ucp-client` gives your agent the same capability
calls as a Ruby object. `Client.discover` reads the store's `/.well-known/ucp` manifest and
connects over whatever transport it advertises:

```ruby
require "portage/ucp"
require "portage/ucp/client"

# Real stores fetch this URL to identify your agent. Over HTTP it's required on every call.
meta = { agent_profile: "https://example.com/agent-profile.json" }

session = Portage::Ucp::Client.discover("https://your-shop.example")

results = session.search_catalog(query: "snowboard", limit: 5, meta: meta)
product_id = "..." # the person picks from results; the result shape is the store's

checkout = session.create_checkout(line_items: [{ product_id: product_id, quantity: 1 }], meta: meta)

if checkout["status"] == "requires_escalation"
  # Normal, not a failure: hand the person the link.
  puts "Finish here: #{checkout['links'].first['url']}"
else
  # Only after the person approves this checkout's total.
  session.complete_checkout(checkout_id: checkout["id"], payment_token: token_from_enrollment, meta: meta)
end
```

Results come back as plain hashes shaped by the store. Without `meta:` an HTTP call raises
`MissingAgentProfileError` before anything is sent. `complete_checkout` takes a tokenized credential, never a card number: a raw card number is
rejected client-side before it reaches the wire. Each mutating call gets an idempotency
key, so a retry replays instead of charging twice. The full sequence is in the
[walkthrough](walkthrough.md), and every method is in the
[`portage-ucp-client` API](api/portage-ucp-client.md). Stores that verify the caller need
an [agent profile](agent-profile.md). If the store's manifest won't connect, see
[tool gating](ucp-tool-gating-investigation.md).

### Over MCP from any agent

A store's UCP manifest names its MCP endpoint, so any MCP-capable agent can call its
catalog, cart and checkout tools directly. Load the
[`shop-via-ucp` skill](skills/shop-via-ucp.md) into that agent: it encodes the sequence
and the guardrails (discover before sending credentials, handle `requires_escalation`,
reject raw card numbers, never pay for a checkout that doesn't match what the person
approved) so you don't have to re-derive them. For lookups only, load the read-only
[`browse-via-ucp` skill](skills/browse-via-ucp.md), which never creates a cart or checkout.

## Checklist

- The person picks the store and approves every payment, enforced in code.
- The model has narrow tools, not a shell.
- `portage policy set --require-approval person` when the agent runs from the person's own
  terminal. Know its limits (above): it isn't a hard guarantee against an agent with a shell.
- `pick` and `approve` are always called with `--json`, never with `--via tty`.
- Spending caps are set (`portage policy set`).
- Only `purchased` counts as bought; every hand-off gives the person `checkout_url`.
- No retries without checking `history` or `orders reconcile` first.
- Store text is data, not instructions.
- Amazon and other hand-off-only retailers are never automated.

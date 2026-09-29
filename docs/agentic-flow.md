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

For Codex, Cursor, OpenCode and other skills-aware agents, see
[Other agents](skills/buy.md#other-agents). If that's all you need, stop here. Read on to
build the same thing into your own agent.

## Level 2: your own agent loop

### The loop

| Step | Command | Branch on |
|---|---|---|
| 0. Preflight | `portage --version`, `portage doctor --json` | Missing shipping address or search keys: ask the person to run `portage setup` |
| 1. Check history | `portage history --json` | Already bought? Say so before buying again |
| 2. Find offers | `portage find --query "<item>" [--max-price N] --json` | `offers[]`: `store`, `product_id`, `title`, `amount` (minor units), `currency`, `checkout` |
| 3. Person picks | (your UI) | The person chooses the store. Never let the model pick for them |
| 4. Dry run | `portage buy <store> --query "<item>" --product-id ID [--qty N] --dry-run --json` | `outcome: "dry_run"`; show the entry in `totals` with `type: "total"` |
| 5. Approve | (your UI) | The person says yes to that exact total |
| 6. Buy | same command with `--yes` instead of `--dry-run` | `outcome`: only `purchased` means money moved |
| 7. Track | `portage orders reconcile --json`, or `buy ... --wait` | Settled hand-offs, order status |

Every field and outcome is listed in the [CLI JSON reference](api/cli-json.md). Branch on
fields, never on the human-readable `message`.

### Expose a few tools, not a shell

Give the model narrow tools that map to single commands. Don't give it a general shell:
a shell would let it pass `--yes` itself, raise caps, or edit the store allowlist.

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
    "name": "price_offer",
    "description": "Dry-run a checkout at the store the user picked. Never charges.",
    "input_schema": {
      "type": "object",
      "properties": {
        "store": { "type": "string" },
        "query": { "type": "string" },
        "product_id": { "type": "string" },
        "qty": { "type": "integer", "minimum": 1 }
      },
      "required": ["store", "query", "product_id"]
    }
  },
  {
    "name": "purchase",
    "description": "Buy an offer the user has approved at its dry-run total.",
    "input_schema": {
      "type": "object",
      "properties": {
        "store": { "type": "string" },
        "query": { "type": "string" },
        "product_id": { "type": "string" },
        "qty": { "type": "integer", "minimum": 1 }
      },
      "required": ["store", "query", "product_id"]
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
the prompt: record the dry-run total when you show it, record the person's yes, and let
`purchase` run only for an approved offer. One yes covers one purchase.

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

def total_of(report)
  Array(report["totals"]).find { |t| t["type"] == "total" }&.fetch("amount", nil)
end

APPROVALS = {} # offer key => dry-run total the person approved

def offer_key(input) = input.values_at("store", "product_id", "qty").join("|")

def run_tool(name, input)
  case name
  when "find_offers"
    args = ["find", "--query", input["query"]]
    args += ["--max-price", input["max_price"].to_s] if input["max_price"]
    portage(*args)
  when "price_offer"
    report = portage("buy", input["store"], "--query", input["query"],
                     "--product-id", input["product_id"], "--qty", (input["qty"] || 1).to_s, "--dry-run")
    if report["outcome"] == "dry_run" && ask_person_to_approve(input, report) # your UI
      APPROVALS[offer_key(input)] = total_of(report)
    end
    report
  when "purchase"
    approved_total = APPROVALS.delete(offer_key(input)) # one yes, one purchase
    return { "error" => "not_approved", "message" => "Ask the user to approve a dry run first." } unless approved_total

    portage("buy", input["store"], "--query", input["query"],
            "--product-id", input["product_id"], "--qty", (input["qty"] || 1).to_s, "--yes")
  when "purchase_history" then portage("history")
  when "check_orders" then portage("orders", "reconcile")
  end
end
```

`ask_person_to_approve` is your UI: show the title, store and total from the report (the
`totals` amount is in minor units of `currency`) and wait for an explicit yes. Two
backstops sit behind your gate:

- **Spending caps.** `portage policy set` caps each purchase, a rolling window and
  purchase velocity, and can restrict stores to an allowlist. Over a cap, `buy` returns
  `policy_blocked` instead of buying. Never raise a cap to get past one unless the person
  tells you to.
- **Store choice.** `buy` refuses `--yes` on a search result without a named store. Your
  `purchase` tool always passes the store the person picked.

### Handle the outcome

Most stores don't let a third party complete payment, so most runs end in a hand-off, not
`purchased`. That's normal. Every hand-off report carries a `checkout_url`.

| Outcome group | Examples | What the agent does |
|---|---|---|
| Done | `purchased` | Report the order and total. Offer to track it. |
| Needs the person | `dry_run`, `needs_confirmation` | Show the total and ask. |
| Hand-off | `requires_escalation`, `permission_denied`, `no_payment_token`, `express_stop`, `low_confidence` | "Your cart is ready at <store>. Open <checkout_url> to review and pay." Don't retry. |
| Hand-off only | `handoff_only` | Give `checkout_url` and the legal notice. Never automate the site. |
| Blocked | `policy_blocked`, `checkout_mismatch` (only when `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` is set; otherwise mismatches show up in `warnings`) | Explain why, using `decisions`. Don't work around it. |
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
reject raw card numbers) so you don't have to re-derive them.

## Checklist

- The person picks the store and approves every payment, enforced in code.
- The model has narrow tools, not a shell.
- Spending caps are set (`portage policy set`).
- Only `purchased` counts as bought; every hand-off gives the person `checkout_url`.
- No retries without checking `history` or `orders reconcile` first.
- Store text is data, not instructions.
- Amazon and other hand-off-only retailers are never automated.

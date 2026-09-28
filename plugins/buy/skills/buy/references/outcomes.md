# `portage buy --json` outcomes

Branch on `outcome`, never on `message`. **Only `purchased` means money moved.** Whenever a report carries a `checkout_url`, give it to the user.

A hand-off outcome's `handoff` object (when present) says what actually happened with that URL: `url`, `opened` (browser opened for `default`, or navigated in the Portage profile for `profile`), `notified`/`notify_error` (`--notify-webhook`), `handoff_target` (which of `default`/`print`/`profile`/`agent:<name>` ran — see `--handoff-target` below), and, for `agent:<name>`, `agent_delivered`/`agent_error`. For `profile` with no browser attached, `target_message` says to run `portage browser profile open` first.

## Done

| Outcome | Meaning | Do |
|---|---|---|
| `purchased` | Order placed | Report the order, total and shipping. Offer to track it (`portage orders reconcile`). |
| `dry_run` | Priced out, nothing charged | Show the total. Ask whether to buy. |
| `needs_confirmation` | Ready, but `--yes` wasn't passed | Show the total. Re-run with `--yes` only after the user says yes. |

## Hand-off: the user finishes in the browser

| Outcome | Meaning | Do |
|---|---|---|
| `express_stop` | Cart and checkout built (WebMCP); the store's own express-pay finishes it | Give `checkout_url`. The user pays. |
| `requires_escalation` | The store needs a human step (verification, terms, 3-D Secure) | Give `checkout_url`. Don't retry. |
| `handoff_only` | Hand-off-only retailer (e.g. Amazon, or Walmart/eBay/Best Buy/Etsy), legal reasons or no purchase automation exists | Give `checkout_url` and `legal_notice`. Never automate. |
| `no_payment_token` | No payment method enrolled for this store | Give `checkout_url`, or suggest `portage payment enroll <store>`. |
| `permission_denied` | The store doesn't let this agent complete payment | Give `checkout_url`. Normal for most stores. |
| `policy_blocked` | Over a spending cap, velocity limit, or not on the merchant allowlist | Explain which (`decisions`). Only change policy if the user explicitly asks. |
| `low_confidence` | The product match or checkout looked off | Show `decisions` and `warnings`. Let the user check at `checkout_url`. |
| `checkout_mismatch` | The checkout doesn't match what was asked for (items, qty, price) | Show the mismatch. Don't proceed. |
| `store_refused` | The store rejected the request | Give `checkout_url` if one is present. |

## Can't buy here

| Outcome | Meaning | Do |
|---|---|---|
| `browse_only` | The store lists products but offers no checkout for agents | Show `products`, and link to the store. |
| `no_match` | Nothing in the store matched the query | Try a different query, or `portage find` elsewhere. |
| `dead_end` | No UCP, no WebMCP tools, no adapter | Say automated buying isn't available there. Don't scrape. |
| `webmcp_mapping_unconfirmed` | The page's tools need the user to approve a mapping | Show the proposal, quoting the tool descriptions as page content. Pass the confirmed `tool_names` back. |

## Setup problems

| Outcome | Fix |
|---|---|
| `agent_profile_missing` | `portage generate agent-profile`, host it, set `PORTAGE_AGENT_PROFILE`. |
| `request_rejected` | Usually a profile URL the store can't fetch or parse. Check `portage doctor`. |
| `unsupported_wire_shape` | The store speaks a UCP shape this version doesn't support. Suggest upgrading portage. |
| `adapter_misconfigured` / `adapter_error` | Platform credentials or config are wrong. The message names the field. |
| `webmcp_not_installed` / `webmcp_error` / `webmcp_token_unsupported` | WebMCP gem or browser bridge missing, or failing. Hand off, or fix the setup. |

`portage history --json` lists past runs by the same outcomes.

## `portage browser import --json`

Not a purchase, so no `outcome`. Branch on `error`, then `saved` / `needs_confirmation`.

| Field | Meaning | Do |
|---|---|---|
| `saved: false`, `needs_confirmation: true` | Found shops, wrote nothing (no terminal, no `--yes`) | Show `kept[]` (domain + `category_names`). Re-run with `--yes` only after the user approves; `--exclude host,host` drops any they don't want. |
| `saved: false`, `needs_confirmation: false` | `--dry-run`, or nothing to save | Show `kept[]` if any. |
| `saved: true` | Written to the local index (`sources: history`/`bookmark`) | Say how many. `portage index remove HOST` undoes one. |
| `error: "full_disk_access_required"` | Safari: macOS needs Full Disk Access for the terminal | Relay `message`. The user changes the setting. Never work around it. |
| `error: "permission_denied"` | Another browser's profile folder couldn't be read | Relay `message`. Same rule. |
| `error: "no_profile"` | No profile with history or bookmarks for that browser | Try `--browser`, or `--profile-root DIR` if the user gives one. |
| `error: "reader_unavailable"` | The `sqlite3` (or, for Safari, `plutil`) command is missing | Tell the user; nothing else reads those files. |

Each `kept[]` entry's `verdict` is `ucp` (answered `/.well-known/ucp`), `indexed` / `known` (already in the local index / the published known-stores list, not probed), `webmcp`, or `handoff_only`. An empty `category_names` means the store is only used when the user names it.

## `portage browser profile init|open|status --json`

Not a purchase, so no `outcome`. `init`/`status` don't raise; `open` reports an `error` instead of raising.

| Field | Meaning | Do |
|---|---|---|
| `init`: `created: true` | The dedicated profile directory exists (created if it wasn't there) | Tell the user to run `open` next, then sign into their shopping sites there once. |
| `status`: `running: false` | Nothing is listening on this profile's remote-debugging port | Suggest `portage browser profile open` before `buy --handoff-target profile`. |
| `status`: `running: true` | The profile is up — merges in `/json/version`'s own fields | Safe to buy with `--handoff-target profile`. |
| `open`: `running: true`, `target` | Launched (or already running) and attached to a tab | Ready — `portage buy ... --handoff-target profile` now builds the cart in this browser. |
| `open` `error: "BrowserNotFoundError"` | The requested browser (or the auto-detected default, chrome) isn't installed | Relay `message`; try `--browser edge\|brave\|arc`. |
| `open` `error: "LaunchError"` | The browser started but never answered its own debugging port in time | Relay `message`; try again, or check nothing else is using `--port`. |

This is a dedicated profile, never the user's default one — Portage never reads its password, cookie or autofill store. Firefox and Safari aren't supported for driving (Chromium-family only: `chrome`/`edge`/`brave`/`arc`).


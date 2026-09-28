# Hand-off-only retailers

Some retailers restrict automated agents in their terms of use. Portage treats them as **hand-off only** by default:

- **Amazon**, every marketplace (amazon.com, .co.uk, .de, .ca, .co.jp, …). Its Conditions of Use restrict robots and automated data extraction. In November 2025 it sued Perplexity over an agent that shopped through users' own logged-in sessions. Using the user's own browser and account was not a defence.
- Any host in `~/.portage/config.json`'s `handoff_only_hosts` (`portage doctor --json`'s `handoff` finding shows the current list). Absent, that key defaults to every Amazon marketplace; once present, the user's list *is* the list — they can drop Amazon or add other hosts. Removing one only changes the message: Portage has no code that automates a site without UCP or WebMCP.

## What `portage buy` does automatically

On a hand-off-only host, `portage buy <url> --query "..."` returns outcome `handoff_only` **before making any request to that host** — no UCP probe, no page fetch, no cart. The report carries:

- `checkout_url`: the product page or a cart-add URL when a product ID is known (Amazon only, today); otherwise the retailer's own search URL for the query (Amazon) or, for a host with no known URL pattern, its homepage. Always built, never fetched.
- `legal_notice`: the facts-only disclaimer below.
- `handoff`: how that URL was delivered — the same `--handoff-target` rules as any other hand-off (`default` opens it, `print` just reports it, `agent:<name>` passes it to an approved agent). See [references/outcomes.md](outcomes.md).

## What you do

1. Give the user the `checkout_url` and say they'll complete the purchase themselves — `portage buy` may have already opened it for them via the `default` hand-off target.
2. Explain in one line: "Amazon doesn't allow automated purchasing agents, so I've opened the page for you to buy it."
3. Don't fetch the site's pages, scrape prices, drive a browser on it, or fill its forms, including with your own browser tools. The user editing the list doesn't make you the one who automates the site.

## What's still fine

- Listing the retailer as a candidate the user already knows (from their bookmarks, history or index).
- Comparing it against a price the user reads out to you.
- Official retailer APIs that Portage integrates as offer sources, where the user has enabled them. These still end in hand-off.

## Disclaimer

Portage is open-source software provided as-is, without warranty of any kind (MIT licence). How it's used on any site, and compliance with that site's terms, is the user's responsibility. Say this when a user asks to automate a hand-off-only site.

## The other big retailers

Walmart, Target, eBay, Best Buy, Etsy, Wayfair and Home Depot don't serve public UCP today (checked 2026-09-28). Their offers, where Portage can see them, end in hand-off too. Their checkouts are never automated through the page.

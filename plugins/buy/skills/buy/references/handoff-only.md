# Hand-off-only retailers

Some retailers restrict automated agents in their terms of use. Portage treats them as **hand-off only** by default:

- **Amazon**, every marketplace (amazon.com, .co.uk, .de, .ca, .co.jp, …). Its Conditions of Use restrict robots and automated data extraction. In November 2025 it sued Perplexity over an agent that shopped through users' own logged-in sessions. Using the user's own browser and account was not a defence.
- Any host the CLI reports with `handoff_only: true`. The list is the user's config, seeded with Amazon. The user can add or remove hosts. Removing one only changes the message: Portage has no code that automates a site without UCP or WebMCP.

## What you do

1. Give the user the product page, or the cart-add link if you have the product ID, and say they'll complete the purchase themselves.
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

# Quickstart

Install the CLI, set it up, and price out a real product without spending anything.
About five minutes. At the end you can hand the same flow to Claude or another agent.

## 1. Install the CLI

=== "Homebrew (macOS, Linux)"

    ```bash
    brew install tomtom87/portage/portage
    ```

    Installs `portage-cli` and every adapter gem on Homebrew's own Ruby, so it doesn't
    touch any Ruby you use for other work.

=== "RubyGems (Ruby 3.2+)"

    ```bash
    gem install portage-cli
    gem install portage-ucp-webmcp   # optional: Portage browser profile and checkout autofill
    ```

    Add an adapter gem only if you hold that platform's credentials (for example your
    own Shopify store): `gem install portage-ucp-shopify`.

Check it worked:

```bash
portage --version   # 0.8.0 or newer
```

Upgrading, two installs on one `PATH`, and the Linux keychain (`secret-tool`):
[CLI reference § Installation](../cli-reference.md#installation).

## 2. Set up

```bash
portage setup
```

The wizard walks through your shipping address, optional search keys, spending caps and
hand-off preferences, one skippable step at a time. It never echoes a secret back, and it
saves to `~/.portage/.env` with `chmod 600`. Run `portage doctor` any time to see what's
still missing.

Prefer editing the file yourself? Set at least the country, since some stores report
in-stock items as out of stock without it. [`.env.example`](https://github.com/tomtom87/Portage/blob/main/.env.example)
lists every variable.

```bash
# ~/.portage/.env
PORTAGE_SHIP_STREET="1 Main St"
PORTAGE_SHIP_CITY="Erie"
PORTAGE_SHIP_COUNTRY="US"
PORTAGE_SHIP_POSTAL_CODE="16501"
```

!!! warning "Only `~/.portage/.env` loads automatically"
    A `.env` in the current directory is never loaded. A cloned repo's `.env` could
    otherwise route your traffic through its proxy or point purchases at another store
    without you noticing. Use a project file on purpose with `PORTAGE_ENV_FILE=.env`.
    [Why](../cli-reference.md#why-env-is-never-loaded-automatically).

## 3. Search and price it out

```bash
portage find --query "burton snowboards" --json
```

`find` works with no keys. Its default search, DuckDuckGo's keyless API, resolves brand
and store names ("burton snowboards") but not open-ended queries ("waterproof hiking
boots"). For those, add a Brave (`BRAVE_SEARCH_API_KEY`) or Google (`GOOGLE_CSE_KEY` +
`GOOGLE_CSE_CX`) key. Each offer comes back with its store, title, price in minor units
(`52995` is $529.95) and whether the store supports automated checkout.

Now price one out. `--dry-run` shows the real total, shipping and tax, and never charges:

```bash
portage buy "burton snowboards" --max-price 600 --dry-run --json
```

With no store URL, `buy` lists the offers and, in a terminal, lets you pick one. Piped or
run by an agent, it prints the offers and stops: a search ranker never chooses the store.
Have a store URL already? `buy` goes straight to its `/.well-known/ucp` manifest:

```bash
portage buy https://some-ucp-store.example --query "hoodie" --dry-run --json
```

## 4. Buy for real

Before the first real purchase:

```bash
portage payment enroll https://some-ucp-store.example       # stores a token, never a card number
portage policy set --per-transaction-cap 20000 --currency USD  # $200.00 cap, in minor units
```

Then drop `--dry-run` and add `--yes`:

```bash
portage buy https://some-ucp-store.example --query "hoodie" --yes --json
```

Most stores don't let a third party complete payment, so expect a hand-off: Portage opens
the checkout in your browser and you pay. Only `"outcome": "purchased"` means money moved;
every other outcome is listed in the [CLI JSON reference](../api/cli-json.md). Hand-off
tiers and hand-off-only retailers such as Amazon: [CLI reference § Tiers](../cli-reference.md#tiers-how-a-purchase-actually-finishes).

## 5. Let an agent do it

In Claude Code:

```text
/plugin marketplace add tomtom87/Portage
/plugin install buy@portage
```

Then ask: `/buy a burton snowboard under $600`. Claude runs the same steps you just ran,
shows you the offers and the dry-run total, and waits for your yes. Update, removal, and
setup for Codex, Cursor, OpenCode and other agents: [buy plugin](../skills/buy.md#install).

## Next steps

- [Agentic flow tutorial](../agentic-flow.md): build your own agent loop around `portage`.
- [CLI usage tutorial](../cli-usage-tutorial.md): store allowlists, the local store index,
  browser import, and what to do when search comes back empty.
- [CLI reference](../cli-reference.md): every command, flag and environment variable.
- [Library usage](../library-usage.md) and the [API reference](../api/index.md): embed
  Portage in a Ruby app instead of shelling out.
- [Running behind a proxy](../proxy.md).

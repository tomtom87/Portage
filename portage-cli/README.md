# portage-cli

Ships the `portage` executable — one CLI command to buy from any store, native
UCP or not.

```bash
portage buy https://your-shop.example --query "snowboard" --qty 1 --payment-token spt_1a2b3c...
```

`portage buy <url>`:

1. Tries native UCP discovery first (`GET /.well-known/ucp`, then a `<link
   rel="ucp">`-style tag on the homepage) — zero credentials, works on any
   store that's opted in.
2. Falls back to a `portage-ucp-<platform>` adapter **only** when this process
   already has that platform's own credentials in env — i.e. it's your own
   store, or one you're integrated with.
3. Otherwise says so plainly and stops — never scrapes or session-hijacks as an
   anonymous shopper. That fallback path is a ToS violation this gem
   deliberately refuses to take.

Depends on [`portage-ucp`](https://github.com/tomtom87/Portage/tree/main/portage-ucp)
(for platform detection via `Resolver`) and
[`portage-ucp-client`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-client)
(for the actual buy calls). No single adapter gem is a hard dependency — install
whichever `portage-ucp-<platform>` gem matches the store you're integrated with,
if any.

## Installation

```ruby
# Gemfile
gem "portage-cli"
```

```bash
bundle install
```

Or standalone:

```bash
gem install portage-cli
```

## Usage

```bash
portage buy <url> --query "..." [--qty N] [--payment-token TOKEN] [--yes] [--dry-run] [--json]
```

- `--query` — search term against the store's catalog.
- `--qty` — quantity, default `1`.
- `--payment-token` — a tokenized payment credential (never a raw card number —
  `PaymentTokenGuard` in the core gem rejects those before they reach the wire).
  Omit for `--dry-run` or to just browse.
- `--yes` — skip the confirmation prompt before completing checkout.
- `--dry-run` — resolve and price the order without completing checkout.
- `--json` — machine-readable report instead of the human-readable summary.

Exits `0` when a checkout completed (or a dry-run/browse resolved successfully),
`1` otherwise — including the "no native manifest, no adapter credentials"
dead-end case, so it's scriptable in CI.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.

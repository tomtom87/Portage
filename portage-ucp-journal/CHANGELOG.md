# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

## [0.1.1] - 2026-09-17

- No behavior change — widens the development-only `portage-ucp` dependency
  pin to `~> 0.8` so this gem's own suite runs against `portage-ucp` 0.8.0.
  There is still no runtime dependency on `portage-ucp` at all.

## [0.1.0] - 2026-09-15

- Initial release: `Portage::Ucp::Journal::Store` (the injectable, append-only
  persistence seam design-log §22 asks for), `FileStore` (its JSON-Lines
  default), and `PurchaseJournal` (one entry per line item of a settled
  `Order` — store origin, source, product id, quantity, amount in minor
  units + currency, order id, idempotency key, timestamp).
- No runtime dependency on `portage-ucp` — wires into `Dispatcher` via its
  new optional `journal:` argument from the consumer's own app.

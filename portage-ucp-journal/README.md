# Portage::Ucp::Journal

A buyer-side, append-only purchase journal for `portage-ucp` — store origin,
source, product, amount (minor units + currency), order id, idempotency key,
and timestamp for every completed purchase — built on a small, injectable
`Store` interface in the same mold as core's `RateLimiter`/`Authenticator`
(design-log §22).

This gem has no runtime dependency on `portage-ucp` itself, and `portage-ucp`
has none on this gem — core's `Dispatcher` gained an optional `journal:`
argument (nil by default, a no-op when absent) rather than requiring this
gem. You opt in from your own app.

## Usage

```ruby
require "portage/ucp/journal"

journal = Portage::Ucp::Journal::PurchaseJournal.new # FileStore, ~/.portage/journal.jsonl, by default

dispatcher = Portage::Ucp::Dispatcher.new(adapter: my_adapter, journal: journal)
# ... complete_checkout dispatches as normal; each settled checkout that
# produces an order confirmation now gets one journal entry per line item.

journal.all
# => [{"shop"=>"example.myshopify.com", "source"=>"adapter:shopify",
#      "product_id"=>"sku_1", "quantity"=>2, "amount"=>2000, "currency"=>"USD",
#      "order_id"=>"order_1", "idempotency_key"=>"idem_1",
#      "recorded_at"=>"2026-09-15T12:00:00Z"}, ...]
```

## Swapping the store

`PurchaseJournal.new(store: your_store)` accepts anything implementing
`Portage::Ucp::Journal::Store`'s two methods (`#append(record)`,
`#each_record(&block)`). `FileStore` is the shipped default; nothing else
ships today (see `docs/plans/storage-abstraction-journal.md`'s open
decisions) — write your own `Store` subclass for Redis, a real database,
or an in-memory double for tests.

## What this is not

- Not `Support::TransactionLog` (payment-dispatch bookkeeping — reserve/
  commit, spend caps) or `Support::OrderLedger` (a settled-order snapshot
  keyed for lookup). Both stay in core `portage-ucp` — as of design-log §33
  they gained the same pluggable-`Store` seam this gem has, but the classes
  themselves did not move.
- Not a console, a CLI history command, or a scheduler. This gem is the
  write path and the shared `Store` seam those would read from and build
  on, not the read/UI surface itself.

# portage-ucp-journal API

`portage-ucp-journal` (0.1.1) keeps a buyer-side, append-only record of what your agent bought, where and for how much.

Use it when you want one durable purchase trail across every adapter. It has no runtime dependency on `portage-ucp`. Core's `Dispatcher` takes an optional `journal:` and calls it, so you opt in from your own app. See [portage-ucp](portage-ucp.md) for the core side.

```ruby
require "portage/ucp/journal"
```

## PurchaseJournal

`Portage::Ucp::Journal::PurchaseJournal` builds one record per line item and hands it to a `Store`.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `new` | `PurchaseJournal.new(store: FileStore.new, clock: -> { Time.now })` | `PurchaseJournal` | `clock` is any callable returning a `Time`. Use it to fix time in tests. |
| `record_checkout` | `record_checkout(shop:, source:, checkout:, idempotency_key:)` | `Array<Hash>` | Writes one entry per line item. Returns the entries written. |
| `each_record` | `each_record(&block)` | Enumerator without a block | Delegates to the store. |
| `all` | `all` | `Array<Hash>` | Every record, in write order. |

`record_checkout` arguments:

- `shop`: the merchant identity string, or nil.
- `source`: `"native_ucp"` for a direct dispatch, `"adapter:<platform>"` otherwise.
- `checkout`: duck-typed. It must answer `#currency`, `#line_items` and `#order` (which may be nil). Each line item answers `#item` (with `#id`), `#quantity` (an Integer) and `#totals` (objects with `#type` and `#amount`). `Portage::Ucp::Checkout` fits.
- `idempotency_key`: joins the entry to the core transaction and order records from the same dispatch.

Source: `portage-ucp-journal/lib/portage/ucp/journal/purchase_journal.rb`

### Record shape

Each record is a Hash with string keys.

| Key | Value |
|---|---|
| `"shop"` | The `shop:` you passed. |
| `"source"` | The `source:` you passed. |
| `"product_id"` | `line_item.item.id`. |
| `"quantity"` | `line_item.quantity`. |
| `"amount"` | Integer minor-unit amount of the line item's `total` entry in `totals`, or nil if there is none. |
| `"currency"` | `checkout.currency`. |
| `"order_id"` | `checkout.order&.id`. |
| `"idempotency_key"` | The key you passed. |
| `"recorded_at"` | UTC ISO 8601 string. |

## Wiring it into a purchase

Pass the journal to core. The `Dispatcher` calls `record_checkout` when a `complete_checkout` settles with an order confirmation.

```ruby
journal = Portage::Ucp::Journal::PurchaseJournal.new

# Directly:
dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter, journal: journal)

# Or through the client's loopback transport (server_opts reach Mcp::Server.build):
session = Portage::Ucp::Client.for_adapter(adapter, journal: journal)
```

Source: `portage-ucp/lib/portage/ucp/mcp/server.rb`, `portage-ucp-client/lib/portage/ucp/client.rb`

## Store

`Portage::Ucp::Journal::Store` is the abstract base. It has two methods and no default behaviour: both raise `NotImplementedError`.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `append` | `append(record)` | Your choice | `record` is a Hash. Persist it as given. `FileStore` returns the record. |
| `each_record` | `each_record(&block)` | Enumerator without a block | Yield each record in write order. |

### FileStore

The default store. One JSON object per line in a JSON Lines file.

| Item | Value |
|---|---|
| Constructor | `FileStore.new(path: FileStore::PATH)` |
| `FileStore::PATH` | `~/.portage/journal.jsonl` |
| Write | Appends one line under an exclusive `flock`, creating the file with mode `0600`. |
| Read | Under a shared `flock`. A torn last line is skipped. A bad line elsewhere raises `JSON::ParserError`. |

Writes raise on failure. Nothing is silently dropped.

Source: `portage-ucp-journal/lib/portage/ucp/journal/store.rb`, `portage-ucp-journal/lib/portage/ucp/journal/file_store.rb`

### Writing a custom Store

Subclass `Store`, call `super()` in your constructor, and implement both methods. Raise on a failed write. A lost write is a hole in the buyer's record.

```ruby
class MemoryStore < Portage::Ucp::Journal::Store
  def initialize
    super()
    @records = []
  end

  def append(record)
    @records << record
    record
  end

  def each_record(&block)
    return enum_for(:each_record) unless block

    @records.each(&block)
  end
end

journal = Portage::Ucp::Journal::PurchaseJournal.new(store: MemoryStore.new)
```

## End to end

```ruby
require "portage/ucp/journal"

Total = Struct.new(:type, :amount)
Item = Struct.new(:id)
Line = Struct.new(:item, :quantity, :totals)
Order = Struct.new(:id)
Checkout = Struct.new(:currency, :line_items, :order)

checkout = Checkout.new("GBP", [Line.new(Item.new("sku_1"), 2, [Total.new("total", 2000)])], Order.new("order_1"))

journal = Portage::Ucp::Journal::PurchaseJournal.new(store: Portage::Ucp::Journal::FileStore.new(path: "/tmp/journal.jsonl"))
journal.record_checkout(shop: "shop.example", source: "native_ucp", checkout: checkout, idempotency_key: "idem_1")

journal.all.first
# => {"shop"=>"shop.example", "source"=>"native_ucp", "product_id"=>"sku_1", "quantity"=>2,
#     "amount"=>2000, "currency"=>"GBP", "order_id"=>"order_1", "idempotency_key"=>"idem_1",
#     "recorded_at"=>"..."}
```

In real use you rarely call `record_checkout` yourself. Pass the journal to the `Dispatcher` and read it with `journal.all`. For the client that drives the purchase, see [portage-ucp-client](portage-ucp-client.md).

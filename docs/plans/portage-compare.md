# `portage compare` — §22 "find this same item elsewhere" mode

## Context

`docs/design-log.md` §22 flags "switching between suppliers" as new scope: §15's
`portage find` multi-store ranking, pointed at a product the shopper already
has instead of a fresh search query. Two things were left unresolved there:
an offer-identity key (nothing today says two products from two stores are
the same item) and a comparison-cost policy (landed price needs a real
`create_checkout`, which risks abandoned carts on live merchant stores).

User decisions for this build (via clarifying questions):
- **Catalog-price only.** No `create_checkout` step against any candidate
  store. Ranking uses listed price alone. Landed-price/checkout-verification
  stays out of scope, left as a documented follow-up.
- **Configurable result count, default 5**, not a hardcoded top-2 — the
  `--limit` flag caller controls how many ranked candidates come back.
- **Identity input**: store URL + product-id (to resolve "the item"), plus
  optional `--mpn/--sku/--upc/--gtin` the caller can supply directly, on top
  of whatever the origin product's own variant data offers.

## Design

New subcommand `portage compare <url> --product-id ID`, implemented as
`Portage::Cli::Compare < Portage::Cli::Find` — inherits the existing
candidate-discovery/probe/rank pipeline (`portage-cli/lib/portage/cli/find.rb`)
rather than duplicating it, since compare mode *is* find's multi-store
ranking with an extra resolution step in front and an extra scoring tier on
top.

**New file: `portage-cli/lib/portage/cli/compare.rb`**

```ruby
class Compare < Find
  RESULT_LIMIT = 5

  # `identity:` replaces the earlier --mpn/--sku/--upc/--gtin sketch (see
  # "Design gaps" item 9 below) — one repeatable value, not four aliases for
  # the same untyped string corpus. `find_options:` bundles backends:/cache:/
  # throttle: — those three are pure pass-through to `Find`'s constructor and
  # bundling them is what keeps this initializer under `Metrics/ParameterLists`
  # (see "Design gaps" item 4). Resolution happens in `#call`, not here (see
  # item 5) — the constructor only stores inputs.
  def initialize(origin_url:, origin_product_id:, identity: [], results: RESULT_LIMIT, max_price: nil,
                 find_options: {})
    @origin_url = origin_url
    @origin_product_id = origin_product_id
    @explicit_identity = identity
    @result_limit = results
    # `query: nil` — the real query isn't known until #call resolves the
    # origin product; Find's pipeline reads @query at #call time, not
    # construction time, so overwriting it in #call before calling `super`
    # (Find#call) works without Find#initialize needing to run twice.
    super(query: nil, max_price: max_price, **find_options)
  end

  def call
    origin = resolve_origin
    return origin if origin[:message]                # not-found etc. — reportable, not raised

    @origin_host = origin[:host]
    @identity = build_identity(origin[:product])
    @query = origin[:title]
    result = super                                   # runs Find's existing pipeline
    finish(result)
  end
end
```

See "Design gaps" items 5 (`resolve_origin`/`#call` ordering) and 6
(`finish`/`compare_summary`, the message rewrite) below for the concrete
method bodies — the sketch above is intentionally load-bearing only for
shape; the grill section has the version to actually type in.

Key pieces (fill in against the real code, not pseudocode-final):

1. **Origin resolution** (`resolve_origin`): parse `origin_url` → origin,
   `Portage::Ucp::Client.discover(origin)` (same call `Find#discover` already
   uses — deliberately *not* Buy's 3-tier native/homepage/adapter fallback;
   compare mode only works against stores that already speak UCP natively,
   same scope as plain `find`). Then `session.get_product(product_id: origin_product_id)`
   (`Session#get_product`, `portage-ucp-client/lib/portage/ucp/client/session.rb:42`)
   — like every other `Session` call, this goes through `Dispatcher#wrap`, so
   the result is `ProductDetail#to_wire_h` = `{"product" => {...}}`
   (`portage-ucp/lib/portage/ucp/value_objects.rb:164`), not a product —
   unwrap `["product"]` before reading anything off it. nil/not-found is a
   reportable error, not an exception (`Adapter#get_product`'s nil-when-
   not-found posture, `portage-ucp/lib/portage/ucp/adapter.rb:9-12`). Pull
   `title` and first variant's `sku`/`barcodes` off the unwrapped product for
   identity fallback (`Product`/`Variant` in
   `portage-ucp/lib/portage/ucp/value_objects.rb:87-140`) — a plain
   string-keyed wire hash throughout, same as every other `Session` result
   (the struct-vs-wire-hash dual handling this plan originally called for is
   dead code, removed from `Find#field`/`Buy#product_id_of` — see grill item 1).
   `get_product` has no existing callers in `portage-cli` today, so there was
   nothing to fix, only this shape to record before `compare.rb` is written.

2. **Identity**: one repeatable `--id VALUE` flag (see "Design gaps" item 9 —
   `--mpn/--sku/--upc/--gtin` were four names for the same untyped string
   corpus, replaced by a single flag) wins when given; otherwise fall back to
   the origin variant's `sku` and `barcodes` values. This is a loose matching
   corpus (a set of strings), not a typed field — `Variant#barcodes` is
   itself untyped wire hashes (`{"type"=>,"value"=>}`), so don't invent false
   precision by trying to map barcode `type` to GTIN vs UPC vs MPN.

3. **Candidate offers' own identity values**: `Find#offer_for`/`#offer`
   currently only flattens `id`/`title`/`price`/`url` from the top-level
   product (`find.rb:137-151`), plus the offer's `store:` (an origin string,
   e.g. `"https://shop.example"`). Compare needs two things `Find#offer`
   doesn't produce: each candidate's variant sku/barcodes, and a `store_host`
   alongside `store` for origin exclusion (see "Design gaps" item 10 — string
   equality on `store:` misses scheme differences). Override `offer` in
   `Compare` to stash both `identity_values:` and `store_host:` on the
   returned hash rather than modifying `Find` itself — keeps the identity
   concept scoped to Compare, since plain `find` has no use for it. Reading
   the variant off the product: `field(product, "variants")` is an array of
   the same wire hashes `Variant#to_wire_h` produces (never a struct — see
   grill item 1); take the first variant, same "first variant only" scope
   the origin-side identity build already uses (item 1 of this Design list).

4. **Match tiers** — final three-tier list, worked out in full against
   §22's honesty stance in "Design gaps" item 8 below (barcode match vs.
   SKU-only match are not the same strength of evidence, so they don't share
   a tier): `:confirmed` (shared barcode value), `:likely` (shared SKU, or an
   explicit `--id` hit that isn't a barcode match), `:unconfirmed` (same
   search query, nothing shared). Every offer in the report carries its
   `match:` tier; the CLI output must show it next to price, not hide it —
   a comparison mode that silently presents `:unconfirmed` rows as
   equivalent misleads exactly the way §22 warns against.

5. **Ranking**: origin's own store excluded first (by host, item 10), then
   sort by `[match_tier, checkout-ability, price]` — match tier outranks
   price, since a cheaper *wrong* item is a worse answer than a confirmed
   match at a higher price. Truncate to `--results` (default
   `RESULT_LIMIT = 5`; renamed from `--limit` — see "Design gaps" item 7)
   *after* ranking. No hardcoded cap on `--results` itself (user asked for
   "as many as you want") — the real ceiling stays `Find::MAX_PROBES` (12
   candidate origins) × `Find::PER_STORE_RESULTS` (5 per store) already
   governing how many offers exist to rank, same safety net plain `find`
   already has.

**CLI wiring** (`portage-cli/lib/portage/cli.rb`):
- Add `compare` to the subcommand dispatch alongside `find`/`buy`/`history`.
- `compare_option_parser`: positional `<url>`, `--product-id ID` (required —
  error out clearly if missing, don't guess), repeatable `--id VALUE`
  (collects into the `identity:` array — see "Design gaps" item 9), `--results
  N` (default 5 — named `--results`, not `--limit`, since `Find`'s own
  `--limit` already means "candidate origins probed"; see item 7),
  `--max-price N` (reuse existing `to_minor_units` conversion), `--json`.
- `run_compare`: build `Compare.new(...)`, call, format. New
  `format_compare` output (or extend `format_find`'s `offer_line`) that
  prints the match tier per row — e.g. `[confirmed] store — title — price`.

**Spec**: new `portage-cli/spec/portage/cli/compare_spec.rb`, same
conventions as `find_spec.rb`/`buy_spec.rb` (`instance_double(Session, ...)`,
stub `Client.discover` returning a session whose `search_catalog`/
`get_product` stubs return the real wrapped wire shape — see grill items 1–3
— never a bare array or a raw struct). Cover: origin product not found →
reportable error not a raise; origin store excluded from ranked offers;
sku/barcode match ranks above title-only match at a worse price; `--results`
truncates after ranking, not before; explicit `--id` overrides the origin
variant's own sku/barcodes.

**Docs**: `portage-cli/README.md` gets a `portage compare` usage section;
`portage-cli/CHANGELOG.md` entry. `docs/design-log.md` gets a short dated
addendum under/after §22 recording what shipped and what didn't (no
checkout/landed-price step, why, and that it's the same catalog-price-only
compromise §22 named as unvalidated — now built, still unvalidated on the
landed-price question since that part wasn't built) — keeps the log's own
house rule of matching claims to code.

## Verification

- `bundle exec rspec portage-cli/spec/portage/cli/compare_spec.rb` (new) and
  the full `portage-cli` suite (`bundle exec rspec`) to confirm no
  regression to `find`/`buy`.
- Manual smoke: `bin/portage compare https://<ucp-store> --product-id <id>
  --json` against whatever local/dev UCP-speaking fixture the existing
  `find`/`buy` manual testing already uses (check `portage-cli/README.md`
  for the current dev-testing recipe) — confirm origin exclusion, match
  tiers, and `--limit` behave as designed.
- Rubocop if the repo runs it in CI (check `Rakefile`/`.rubocop.yml`
  presence) — match existing style conventions in `find.rb`/`buy.rb`.

---

## Grill review (2026-08-28) — plan checked against real code

Direction is sound (inheriting `Find` is right), but the plan rests on
several factual errors about this codebase, plus design gaps. Items 1–4 are
blocking; fix them before writing `compare.rb`.

**Items 5–9 resolved 2026-08-28** (separate pass, focused on Design-gap
items only — 1–4 and 10–12 untouched by this pass): 5 — resolution moves
into `#call`, concrete `resolve_origin`/`finish` bodies written below; 6 —
`compare_summary` now names excluded/truncated counts instead of reusing
`Find`'s pre-filter message; 7 — `--limit` renamed to `--results` for
compare, `Find`'s probe-cap `limit:` stays reachable only via
`find_options:`; 8 — three tiers (`:confirmed` barcode-only,
`:likely` SKU-or-explicit-`--id`, `:unconfirmed`), title-overlap dropped as
its own tier; 9 — collapses to one repeatable `--id VALUE`, decision
recorded for the parallel Task D handoff to build on rather than
re-litigate.

### Factual errors about the code

**1. The "struct vs wire hash" dual-handling is a myth.** — FIXED (2026-08-28,
prereq commit "Drop the dead struct-vs-wire-hash handling in Find#field and
Buy#product_id_of"): proved unreachable and removed from both `Find#field`
and `Buy#product_id_of`; stale comments rewritten. `compare.rb` should follow
the same posture — every product/variant it touches is a plain string-keyed
wire hash, never a struct.
The plan says twice to handle both `Portage::Ucp::Product` structs and wire
hashes, "same dual handling as `Find#field`/`Buy#product_id_of`". But
`Dispatcher#wrap` (`portage-ucp/lib/portage/ucp/dispatcher.rb:48-54`) calls
`to_wire_h` on *every* result before wrapping, and `Product`,
`CatalogSearchResult` and `ProductDetail` all define `to_wire_h`. Loopback
and stdio differ only in the JSON-RPC envelope's key symbolization
(`portage-ucp-client/lib/portage/ucp/client/tool_result.rb`) — the payload is
string-keyed either way. The comment at `portage-cli/lib/portage/cli/buy.rb:246-251`
("Product has no `#to_wire_h`, see Dispatcher#wrap") is stale. The struct
branch is dead code, and the planned spec case "both struct- and hash-shaped
products" tests a shape nothing produces.

**2. `get_product` does not return a product.** — RECORDED (2026-08-28): no
existing `portage-cli` caller of `get_product` today (checked — none), so
nothing to fix; `resolve_origin`'s sketch above now unwraps `["product"]`
explicitly.
It returns `ProductDetail#to_wire_h` = `{"product" => {...}}`
(`portage-ucp/lib/portage/ucp/value_objects.rb:164`). `resolve_origin` must
unwrap `["product"]`. The not-found-is-nil posture the plan assumed does
hold (`portage-ucp/lib/portage/ucp/adapter.rb:9-12`).

**3. `Find`'s catalog step is already broken, and the plan inherits it.** —
FIXED (2026-08-28, prereq commit "Unwrap search_catalog's wire envelope
instead of treating it as the product list"): new shared
`Portage::Cli::CatalogProducts.from` helper (`portage-cli/lib/portage/cli/
catalog_products.rb`) unwraps all three call sites — `find.rb:130`,
`buy.rb:134` (adapter path — genuinely gets a raw `CatalogSearchResult`
struct, confirmed different from the other two, which get the
Dispatcher-wrapped wire hash), `buy.rb:302`. Suite confirmed failing before
(bare-array stubs hid it) and passing after with the stubs corrected to the
real wrapped shape plus a regression example per call site.
`search_catalog` returns `CatalogSearchResult#to_wire_h` plus envelope:
`{"ucp" => ..., "products" => [...]}`. `Find#offers_for`
(`portage-cli/lib/portage/cli/find.rb:130`) does
`Array(session.search_catalog(...))`, and
`Array({"ucp"=>1,"products"=>[...]})` evaluates to
`[["ucp",1],["products",[...]]]` (verified in irb). Every offer against a
real store is a 2-element array, not a product. `find_spec.rb:17` stubs
`search_catalog:` as a bare array, which is why the suite never sees it.
Same bug at `buy.rb:134` and `buy.rb:302`. The plan's instruction to mirror
find_spec's stubbing conventions would replicate the fiction. Fix
`offers_for` to read `["products"]` first — ideally as its own commit ahead
of compare — or compare ships onto sand.

**4. Rubocop will fail the file as written.** — RESOLVED (2026-08-28)
`Metrics/ParameterLists: Max: 7` (`portage-cli/.rubocop.yml`) — the original
sketch's `Compare#initialize` had 9 keywords. `Metrics/ClassLength` excludes
only `buy.rb` and `find.rb`; `compare.rb` is not excluded. The root `Rakefile`
runs rubocop per gem and aborts on failure, so this is CI-blocking, not the
plan's original "rubocop if the repo runs it in CI".

Decision: collapse, not exclude. The revised sketch above folds the four
identity flags into one `identity:` array (item 9) and bundles `Find`'s pure
pass-through options (`backends:`/`cache:`/`throttle:`) into one
`find_options:` hash, leaving 6 keywords (`origin_url:`, `origin_product_id:`,
`identity:`, `results:`, `max_price:`, `find_options:`) — under the Max 7
limit with no exclusion needed. No verdict yet on `Metrics/ClassLength` for
the eventual full `compare.rb` — implementer should run rubocop once the
file is written and only add an exclusion (justified in the same voice as
`buy.rb`/`find.rb`'s) if the real file actually trips it, not preemptively.

### Design gaps

**5. The constructor does network I/O and cannot report.** — RESOLVED
(2026-08-28): revised sketch above moves `resolve_origin` into `#call`;
`#initialize` only stores inputs and calls `super(query: nil, ...)` since
`Find`'s pipeline reads `@query` at `#call` time, not construction time —
`#call` sets the real `@query` after resolving the origin, then calls
`super` (`Find#call`).
The planned `initialize` calls `resolve_origin` (discover + get_product) and
says it "may raise a reportable error" — but a constructor cannot return a
report, contradicting the plan's own spec case "origin product not found →
reportable error not a raise". Move resolution into `call`, before `super`.

Concrete shape, replacing the `#call` sketch above:

```ruby
def call
  origin = resolve_origin
  return origin if origin[:message]          # short-circuit: Find-shaped report, never raised

  @origin_host = origin[:host]
  @identity = build_identity(origin[:product])
  @query = origin[:title]
  result = super                             # Find#call — candidates/probe/rank pipeline
  finish(result)
end

private

# Every failure path returns the same shape `Find#report` does (query/
# candidates/stores/offers/message), just built by hand since Find#report
# needs @query set and @query isn't known yet at this point — that's the
# whole reason resolution can't live in #initialize. A blank @query here
# is fine; it's never read.
def resolve_origin
  uri = parse_http(@origin_url)
  return report(message: "Not a store URL: #{@origin_url.inspect}") unless uri

  session = discover(origin_of(uri))
  return report(message: "#{origin_of(uri)} doesn't speak UCP.") unless session

  wrapped = session.get_product(product_id: @origin_product_id)
  product = wrapped.is_a?(Hash) ? wrapped["product"] : nil
  return report(message: "Product #{@origin_product_id.inspect} not found at #{origin_of(uri)}.") unless product

  { host: uri.host, title: field(product, "title"), product: product }
end
```

`parse_http`/`origin_of`/`discover`/`report`/`field` are all private on
`Find` already (`find.rb:90-102`, `125-129`, `191-193`, `189`) — Ruby
private methods are callable from a subclass instance with no `send`, so
`Compare` reuses them as-is rather than re-implementing origin parsing.

Failure-path messages, one per case named in the task:
- **origin URL unparseable** — `"Not a store URL: \"ftp://junk\"."` (mirrors
  `Find`'s own posture of naming what was actually passed, e.g.
  `no_candidates_message`'s `"...for \"#{@query}\""`).
- **store doesn't speak UCP** — `"https://shop.example doesn't speak UCP."`
  — same fact `Find#probe` already discovers per-candidate, just surfaced
  immediately here since there is only one origin to check, not twelve.
- **product-id not found** — `"Product \"abc123\" not found at
  https://shop.example."` — matches `Adapter#get_product`'s nil-is-not-found
  posture (item 2 above): a miss is data, not an exception, so it is worded
  as a fact, not an error.

**6. `message:` will lie.** — RESOLVED (2026-08-28). `Find#call`'s report
carries `summary(...)` computed before compare's filtering. After excluding
the origin store and truncating to `--results`, the message claims "Found 9
offer(s)" above 5 rows. §22's honesty stance ("a security posture that's
only true in the design log is worse than one that's honestly absent")
applies just as much to a results count as to a security claim, so the
excluded counts get named rather than silently dropped.

`finish(result)` (called from `#call` above) rewrites the message:

```ruby
def finish(result)
  offers = result[:offers].reject { |o| o[:store_host] == @origin_host }
  excluded_origin = result[:offers].length - offers.length
  scored = offers.map { |o| o.merge(match: match_tier(o)) }
  ranked = scored.sort_by { |o| [TIER_RANK[o[:match]], o[:checkout] ? 0 : 1, o[:amount] || 0] }
  kept = ranked.first(@result_limit)
  result.merge(offers: kept, message: compare_summary(kept, ranked.length - kept.length, excluded_origin))
end

def compare_summary(kept, truncated, excluded_origin)
  return "No comparable offers found for \"#{@query}\" outside #{@origin_host}." if kept.empty?

  parts = ["Found #{kept.length} offer(s) for \"#{@query}\""]
  parts << "#{truncated} more not shown (--results #{@result_limit})" if truncated.positive?
  parts << "#{excluded_origin} excluded (origin store)" if excluded_origin.positive?
  "#{parts.join(', ')}."
end
```

Example: 9 raw offers, 1 is the origin store, `--results` default 5 →
`"Found 5 offer(s) for \"Wool Throw\", 3 more not shown (--results 5), 1
excluded (origin store)."` This is why item 10's host-based exclusion has to
happen *before* the message is built, not after — the excluded count would
be wrong otherwise.

**7. `--limit` means two different things.** — RESOLVED (2026-08-28)
`Find#initialize(limit:)` caps *candidate origins probed*
(`[limit, MAX_PROBES].min`). Compare's `--limit` is a result count and isn't
passed to `super`. Same flag name, different semantics between `find` and
`compare`. Decision: rename to `--results` / `results:` (see revised sketch
above) — `Find`'s own probe-count `limit:` stays reachable only via
`find_options:` if a future caller needs it, which nothing in this plan does.

`Cli::USAGE` line to add:

```
portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                       [--max-price N] [--json]
```

Both knobs are nameable at once (`find_options: { limit: N }` alongside
`--results N`) since they govern different pipeline stages — probe-cap
first, result-count last — so there is no conflict to resolve when both are
passed; they just compose. `compare_option_parser` does not expose
`find_options[:limit]` as a flag at all in this build (nothing in the task
asks for it), so in practice a caller can only reach it by constructing
`Compare` directly, not via the CLI — worth a one-line README note so it
isn't mistaken for an oversight.

**8. `:confirmed` on a shared SKU is the exact overclaim §22 warns about.**
— RESOLVED (2026-08-28). SKUs are merchant-internal — `BLACK-M`, `SKU-001`
collide across unrelated stores constantly. `Variant#barcodes`
(`portage-ucp/lib/portage/ucp/value_objects.rb:82-110`) confirms barcodes
are an array of untyped wire hashes, `[{"type"=>, "value"=>}, ...]` — no
GTIN/UPC/MPN distinction exists in the data, so tiering can key on "is a
barcode" but never on "is a GTIN specifically". Final tier list, replacing
item 4's three-tier sketch:

- **`:confirmed`** — a non-blank `barcodes[].value` shared (case-insensitive,
  trimmed) between origin and candidate. Barcodes are the one identity value
  the spec itself treats as globally unique regardless of merchant.
- **`:likely`** — no barcode match, but a non-blank `sku` shared
  case-insensitively, OR an explicit `--id VALUE` matches any identity value
  on the candidate (barcode or sku) without matching the origin's own
  barcode. Two different kinds of evidence land in `:likely` deliberately:
  a caller-supplied `--id` is exactly as unverifiable as an origin SKU match
  — both are "some string matched", not "a global identifier matched" — so
  collapsing them into one tier rather than inventing a fourth is the
  honest call, not a missed distinction.
- **`:unconfirmed`** — passed the same catalog search query, no identity
  value shared at all. Title token-overlap is dropped as its own tier (the
  original plan's middle tier) — word-overlap on a marketing title is
  strictly weaker evidence than a shared SKU, and giving it a separate name
  implied a precision gradient the matcher can't actually stand behind.
  Title overlap still feeds the *fallback* — item 11's recall problem, not
  the tiering — but doesn't buy a candidate a better tier on its own.

Tie rank within a tier: unchanged from the plan's existing rule —
`[match_tier, checkout-ability, price]`, `TIER_RANK = { confirmed: 0,
likely: 1, unconfirmed: 2 }.freeze`.

**9. Four identity flags, one behavior.** — RESOLVED (2026-08-28)
`--mpn/--sku/--upc/--gtin` all add a string to the same untyped
case-insensitive corpus (plan item 2 explicitly refuses to type them). They
are aliases wearing four names, and each one implies a precision — "this is
specifically a UPC" — that item 8's tiering just established the data can't
back up: a value passed via `--upc` gets matched exactly like one passed via
`--sku`, so keeping four flags would mean the flag name lies about
confidence the tier system deliberately doesn't grant it.

Decision: **one repeatable `--id VALUE`** (see revised sketch above). Weighed
against keeping the four: a shopper holding a UPC off a box reaching for
`--upc` is a real ergonomic loss, but the fix for that is documentation
("if you have a UPC/GTIN/MPN/SKU, pass it with `--id`"), not four flags that
silently behave identically — self-documenting flags are only honest when
what they document is true. `--help`/README must say plainly: "`--id` may
be a SKU, barcode (UPC/EAN/GTIN), or MPN — matched identically and
case-insensitively; there's no way to tell the matcher which kind you have,
so it doesn't pretend to." This also satisfies item 4's `ParameterLists`
fix (`identity:` takes the collected `--id` array as one keyword instead of
four).

No overlap with the separate handoff's Task D beyond this: Task D asks for
a decision on collapsing `Compare#initialize`'s keyword list generally: this
resolves it does collapse — `identity:` (single array) supersedes the
`--mpn/--sku/--upc/--gtin` shape, and it composes with `find_options:` (item
4/7's other collapse) to land at 6 keywords total. No further collapsing
needed on top of what's already in the revised sketch; the other agent
should build on this rather than re-deciding it.

**10. Origin exclusion needs normalization.**
`o[:store] == @origin_origin` compares strings, but `Find` normalizes
candidates through `origin_of(uri)` and dedupes by *host* with an
https-preference. A user passing `http://shop.example/products/x` yields an
origin that won't string-match the `https://shop.example` candidate. Reuse
`parse_http`/`origin_of` and compare on host.

**11. Recall, not ranking, is the real ceiling.**
Compare searches on the origin's own title — a store-specific marketing
string. If the backends don't surface the competitor, no tier system helps.
Worth a second search pass on the barcode/SKU string, or at minimum
documenting the limitation next to the match tiers.

**12. Unspecified:** does `run_compare` record to `History` the way
`run_find` does?

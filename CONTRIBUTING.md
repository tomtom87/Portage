# Contributing to Portage

Firstly, thanks so much for taking an interest! Building this project has been a lot of fun and I've always intended it to be a group project that anyone can contribute too and add their ideas! 

As Portage is an open workspace, based on a collection of Ruby gems that expose commerce backends to AI shopping agents over both MCP and UCP there's a ton of things we can add and do, feel free to fork, mod and cook up any wild ideas you like! 

Bug reports, adapters, new features, docs, and spec-conformance fixes are very welcome inded.

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md) — in short: be decent, and never paste real credentials, tokens, or customer PII into an issue or PR.

Before anything else: this project is still slightly **pre-`1.0` and still tracking a moving spec due to how UCP is evolving**. 

The capability/adapter contract is not settled, so things are likely to change. But just go with it, it's all good.

## Table of contents

- [Ways to contribute](#ways-to-contribute)
- [Code of conduct](#code-of-conduct)
- [Reporting a bug](#reporting-a-bug)
- [Reporting a security issue](#reporting-a-security-issue)
- [Development setup](#development-setup)
- [Repository layout](#repository-layout)
- [Running the tests](#running-the-tests)
- [Writing a new platform adapter](#writing-a-new-platform-adapter)
- [Coding style](#coding-style)
- [Commit messages](#commit-messages)
- [Opening a pull request](#opening-a-pull-request)
- [Changelogs](#changelogs)
- [Documentation and the design log](#documentation-and-the-design-log)
- [Releasing (maintainers)](#releasing-maintainers)
- [License](#license)

## Ways to contribute

- **A new platform adapter** — the most welcome kind of PR. See
  [Writing a new platform adapter](#writing-a-new-platform-adapter).
- **Bug fixes**, especially wire-shape mismatches against a real store. Include what the
  store actually returned.
- **Spec conformance** — if Portage's manifest, schemas, or tool shapes have drifted from
  what UCP or MCP now specify, a PR with the spec citation is very useful.
- **Docs** — the README, [`docs/cli-usage-tutorial.md`](docs/cli-usage-tutorial.md), the
  agent [`skills/`](skills/), and the walkthroughs.
- **Reproductions** — a failing spec with no fix attached is still a good contribution.

## Code of conduct

This project ships a [Code of Conduct](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1) that
applies to issues, pull requests, and discussions. Two clauses matter more here than in most
repos, because Portage handles live commerce credentials: never post real credentials, tokens,
payment instruments, or customer PII, and report security issues privately rather than in a
public issue.

## Reporting a bug

Please open an issue at [tomtom87/Portage](https://github.com/tomtom87/Portage/issues) using the
**Bug report** template, which asks for the following to help us track down what's happening:

- Which gem and version (`portage-ucp` 0.8.0, `portage-cli` 0.8.0, …) and your Ruby version.
- What you ran and what happened, with the **exact** error text and backtrace — not a
  paraphrase.
- For anything touching a live store: the platform, and the request/response shape with
  credentials, tokens, and PII redacted.
- Ideally, a failing spec or a minimal script against `Portage::Ucp::ReferenceAdapter`.

Please can you also search existing issues first. A +1 or "me too" on an open issue is ideal... no worries if you didn't see one, no biggie.

Note that some failures against live Shopify stores are **not** Portage bugs: real UCP tool
calls currently hit a platform-side allowlist gate and come back `Tool not found`. See
[`docs/ucp-tool-gating-investigation.md`](docs/ucp-tool-gating-investigation.md) before
filing.

## Reporting a security issue

**Do not open a public issue.** Report it privately to the maintainer — see
[`SECURITY.md`](SECURITY.md), which also documents the trust boundaries Portage assumes
(the `Marshal`-backed idempotency store, payment-token handling, the policy guards). If
you're unsure whether something is a security issue, treat it as one and report privately.

## Development setup

Requires Ruby >= 3.2 (CI runs 3.2 and 3.4).

```bash
git clone https://github.com/tomtom87/Portage.git
cd Portage
```

**Each gem owns its own bundle.** There is no root `Gemfile`, no shared lockfile, and no
cross-gem run-order dependency. Install per gem, in that gem's directory:

```bash
cd portage-ucp && bundle install
```

Adapter gems and the CLI resolve the core gem by path, so a local change to `portage-ucp`
is picked up by the gem you're testing without a release.

Never commit `.env` — it holds live credentials. Copy `.env.example` and fill it in locally.

## Repository layout

| Directory | What it is |
| --- | --- |
| `portage-ucp/` | Protocol core: the `Adapter` contract, capability registry, manifest builder, MCP server wrapper, schema validator, conformance kit. No commerce-backend deps. |
| `portage-ucp-client/` | Client side — discovering and calling a UCP store. |
| `portage-cli/` | The `portage` CLI (`find`, `buy`, `history`, `payment`, `policy`). |
| `portage-ucp-journal/` | Audit journal. |
| `portage-ucp-{shopify,wix,woocommerce,bigcommerce,magento,etsy,instagram}/` | Platform adapters. `shopify` is the most complete reference. |
| `docs/` | Design log, tutorials, investigations. |
| `skills/` | Agent skills (`shop-via-ucp`, `serve-via-ucp`). |

## Running the tests

Per gem, from that gem's directory:

```bash
cd portage-ucp && bundle exec rspec && bundle exec rubocop
```

Across every gem, from the workspace root — this shells into each gem in turn and stops at
the first failure:

```bash
rake spec   # the default task, so bare `rake` works too
```

And the adapter-contract check, which fails if a bundled adapter gem's suite doesn't run the
shared conformance kit:

```bash
rake conformance
```

Run at least the gem(s) you touched before opening a PR. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs rspec and rubocop for every
gem on two Ruby versions plus `rake conformance`, but finding it locally is faster than
waiting on the matrix.

New behavior needs a spec. Bug fixes need a spec that fails before the fix.

## Writing a new platform adapter

The shape of it:

```ruby
class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support — the rest stay unadvertised
end
```

Read `Portage::Ucp::Adapter` for the full method contract and
`Portage::Ucp::ReferenceAdapter` (`portage-ucp/lib/portage/ucp/reference_adapter.rb`) for a
complete in-memory implementation of every capability. `portage-ucp-shopify` is the
reference against a real API.

Then make it prove itself against the contract — schema-valid output can still break the
behavioral guarantees (an idempotency key that doesn't actually dedup, a raw PAN reaching
the adapter, a capability advertised but not round-tripping):

```ruby
# spec/spec_helper.rb
require "portage/ucp/rspec"

# spec/my_adapter_spec.rb
RSpec.describe MyAdapter do
  it_behaves_like "a portage adapter" do
    let(:adapter) { MyAdapter.new(client: my_test_client) }
    let(:existing_product_id) { "known-good-product-id" }
  end
end
```

Every example skips itself when the adapter doesn't advertise the capability it needs, so a
catalog-and-checkout-only adapter still runs the kit cleanly. Include
`Portage::Ucp::Support::Idempotency` (as every bundled adapter does) and the dedup example
checks the dedup table itself rather than just comparing two calls' output.

Checklist for a **bundled** adapter gem (one living in this repo):

1. Gem directory with its own `Gemfile`, gemspec, `spec/`, `.rubocop.yml`, `README.md`, and
   `CHANGELOG.md`, following an existing adapter's layout.
2. `spec/portage/ucp/<platform>/conformance_spec.rb` running the shared kit.
3. Added to `GEMS` **and** `ADAPTER_GEMS` in the root [`Rakefile`](Rakefile).
4. Added to the `gem:` matrix in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
5. Added to the gem table in the [README](README.md).
6. No live network in specs — stub with `webmock`.

An adapter you publish as your own gem outside this repo is equally welcome; open an issue
and we'll link it from the README.

## Coding style

RuboCop is the arbiter — each gem has its own `.rubocop.yml`, and CI enforces it. Beyond
that:

- Double-quoted strings, Ruby >= 3.2 syntax.
- Match the surrounding code's naming and idiom rather than importing a house style.
- Comments are sparse and explain *why*, not *what*. Prefer a comment that records a
  decision or a trap over one that narrates the line below it.
- No new runtime dependency in `portage-ucp` without discussing it first — the core gem
  staying dependency-light (and RSpec-free at runtime) is deliberate.
- Nothing is permissive by default: new capabilities stay unadvertised unless implemented,
  and new credential or payment paths need an explicit guard, not a trusting default.

## Commit messages

This repo keeps a story-style history. Conventional Commits prefixes (`feat:`, `fix:`) are
**not** used.

- Imperative mood, sentence case, no trailing period:
  `Read the catalog through Storefront, not Admin`
- One logical change per commit. If a PR touches a contract and its adapters, split by
  dependency order — the thing being inherited from first.
- The subject usually stands alone. Add a body only when the change is genuinely deep and
  the *why* can't fit in the subject.
- Keep build/lock-file churn (`Gemfile.lock` refreshes, version bumps) in its own commit.

## Opening a pull request

1. Branch off `main`. Name it for the change, not the ticket.
2. Make sure `rspec` and `rubocop` pass for every gem you touched, and `rake conformance`
   if you touched an adapter.
3. Update the affected gem's `CHANGELOG.md` (see below) and the README if you changed
   anything a user sees.
4. Fill in the PR template's **Summary**: a narrative explanation of what changed and why,
   in paragraphs, covering the context that isn't obvious from the commits. Not a bullet
   list restating the diff.
5. Open it and let CI run. Keep the PR focused — unrelated cleanups in the same PR make it
   slower to review, not faster.
6. Address review feedback by amending or fixing up into the commit it belongs to, so the
   merged history reads as if the mistake never happened, rather than adding a
   "fix review comment" commit.

## Changelogs

Each gem keeps its own `CHANGELOG.md` for its own API; the root
[`CHANGELOG.md`](CHANGELOG.md) covers the workspace, shared docs, and anything spanning more
than one gem. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

Add your entry under the unreleased heading of every changelog your change affects. Mark
anything that breaks an existing caller as **breaking** in the entry text — pre-`1.0` means
breaking changes are allowed, not that they go unannounced.

## Documentation and the design log

[`docs/design-log.md`](docs/design-log.md) is the decision history: numbered sections, each
one a dated record of a decision, what was rejected, and why. It's the reason most "why is
it like this?" questions have an answer.

You don't need to add a design-log section to contribute. Do add one (next number, dated,
same shape as the existing entries) when your PR settles a question rather than just
implementing one — a contract change, a rejected alternative worth recording, or a platform
behavior you had to reverse-engineer. Reference existing sections as `§N`.

## Releasing (maintainers)

`gem build` **must** run from inside the gem's own directory — every gemspec's
`spec.files = Dir["lib/**/*.rb", ...]` resolves against the current directory, so building
from the workspace root silently produces a package with no `lib/` (this shipped once; see
the 0.7.1 postmortem in the changelog). The rake tasks encode that:

```bash
rake release_check[portage-ucp]   # build from the right dir, install and require the result
rake publish_all                  # build, verify, and push every gem whose version isn't on rubygems.org
```

Only push once `release_check` passes. RubyGems MFA prompts for a fresh OTP per push, so
`publish_all` pauses at each one.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE), the same terms as the rest of the project.

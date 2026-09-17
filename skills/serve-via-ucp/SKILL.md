---
name: serve-via-ucp
description: Set up a merchant's own backend to serve UCP/MCP commerce to shopping agents — detect the stack, install portage-ucp (+ a platform adapter), write the initializer, mount the manifest/webhook endpoints, and verify the live manifest. Use when asked to expose a store over UCP, add AI-agent checkout to a store, integrate portage-ucp into an app, or self-host a /.well-known/ucp endpoint. Seller-side counterpart to shop-via-ucp. Enforces three guardrails — never write a permissive authenticator, never commit credentials, always run doctor before declaring done.
---

# Serving commerce via UCP/MCP

You are setting up a merchant's own backend to be a UCP/MCP commerce server — the
seller side, not the shopper side (`shop-via-ucp` is the counterpart for acting as a
buyer's agent). The scripts in `scripts/` do the mechanical parts; you drive the
sequence and make the judgment calls a script can't (which adapter gem fits, what the
authenticator should actually check, whether the manifest looks right).

## Guardrails — apply these every time, no exceptions

1. **Never write a permissive authenticator or rate limiter.** The unconfigured
   defaults (`UnconfiguredAuthenticator`, `NullRateLimiter`) reject-by-default /
   never-limit on purpose (see portage-ucp's README, "Security hooks"). If you don't
   know what the real auth check should be, leave the TODO in place and say so — don't
   write `->(context) { true }` just to make `doctor.sh` stop complaining.
2. **Never commit credentials.** Every secret (webhook HMAC secret, PSP keys, platform
   admin tokens) is `ENV.fetch("...")` in the initializer, never a literal string —
   including in examples you write for the user. If a `.env` file is involved, confirm
   it's gitignored before touching it.
3. **Always run `doctor.sh` before declaring the setup done.** A manifest that responds
   over HTTP doesn't mean the setup is safe — `portage doctor` (see `portage-cli`)
   catches the specific footguns nothing else does: unconfigured auth/rate-limiting
   still in place, missing signing keys, missing payment handlers, a capability
   half-implemented (some actions overridden, others still raising
   `NotImplementedError`).

## Sequence

1. **Detect the stack** — `scripts/detect_stack.sh` (run from the app's root). Reports
   framework (Rails vs. plain Rack), which `portage-ucp*` gems are already bundled, and
   whether an `Adapter` subclass already exists. Read-only.
2. **Pick or write an Adapter.** If `detect_stack.sh` found none and no bundled
   platform gem fits (Shopify/Wix/WooCommerce/BigCommerce/Magento/Etsy/Instagram —
   see portage-ucp's README capability matrix for what each actually implements),
   scaffold one with `portage generate adapter Foo` (see portage-cli) rather than
   hand-rolling the boilerplate.
3. **Install** — `scripts/install.sh [adapter-gem-name]`. Adds `portage-ucp` (+ the
   adapter gem, if named) to the Gemfile, then either runs
   `rails generate portage:ucp:install` (Rails apps) or copies the same initializer
   template to `config/initializers/portage_ucp.rb` directly (plain Rack). Idempotent —
   safe to re-run.
4. **Fill in the initializer.** Every TODO in `config/initializers/portage_ucp.rb`
   (authenticator, rate_limiter, business, signing_keys, ...) needs a real value or a
   deliberate "leave unset" decision — this is the step guardrail 1 is about. Mount
   `Rack::ManifestEndpoint` and `Rack::WebhookEndpoint` per the routes the generator
   added (or portage-ucp's README, "Usage", if routing by hand).
5. **Run `doctor.sh [require-file] [adapter-class-name]`** (default require path:
   `config/environment`, i.e. Rails boot). Fix every finding it reports — this is
   guardrail 3. Don't proceed to verify.sh with known findings unaddressed unless the
   user explicitly accepts the risk.
6. **Boot the app** (however this app normally starts — this skill doesn't guess that
   part), then **verify.sh [base-url]** (default `http://localhost:3000`) — curls
   `/.well-known/ucp` and checks it nests `version`/`business`/`services`/
   `capabilities` under a top-level `ucp` object, with at least one advertised capability.
7. **Run the conformance kit** — `scripts/conformance.sh [spec-path]`. Fails loudly
   with a worked example if no spec includes `"a portage adapter"` yet (see
   portage-ucp-etsy's conformance spec in the Portage repo for a real one to copy the
   shape of); otherwise runs it. This is the same shared-examples kit
   `rake conformance` gates the bundled adapters on — see portage-ucp's
   `lib/portage/ucp/rspec.rb`.

## What "done" looks like

`doctor.sh` reports no findings (or the user explicitly accepted the remaining ones),
`verify.sh` confirms a well-formed live manifest, and `conformance.sh` passes against
the merchant's own `Adapter`. Report which of these three actually ran and passed —
don't claim the integration is safe on the strength of "the server responds."

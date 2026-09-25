# Homebrew Distribution: `brew install portage`

**Status:** Phase 1's in-repo half is done: the generator, `portage --version`, and the `irb` dependency fix. The tap repo doesn't exist yet. See [Handoff](#handoff-phase-1-status-and-next-steps) at the end.
**Driver:** today `portage` installs only with `gem install portage-cli`. That assumes a working Ruby ≥ 3.2 and a writable gem home, and it puts the CLI's gems in the user's global gem set. Homebrew is how most macOS (and many Linux) developers expect to install a CLI, and the goal here is a one-line install on macOS. It should give a self-contained `portage` that doesn't depend on, or interfere with, whatever Ruby the user has.

## Context

**Pure-Ruby gems with few dependencies.** `portage-cli` needs `portage-ucp`, `portage-ucp-client` and `portage-ucp-journal`. Their transitive runtime dependencies are `base64`, `json_schemer` (and its own), `mcp`, `rack` and `faraday` (and its adapter gems). Every first-party adapter gem (shopify, wix, woocommerce, bigcommerce, magento, etsy, instagram) needs only `portage-ucp`. `webmcp` adds `rack` and the client, which are already present. `decision` adds `faraday`, also already present. **So bundling every first-party adapter costs almost nothing** and saves users a second `gem install` into a Homebrew-managed gem home they can't easily find.

**Homebrew's pattern for Ruby CLIs** (as used by formulae like `cocoapods`, `fastlane`, `licensed`):
- `depends_on "ruby"`;
- each gem declared as a `resource` with URL and `sha256`;
- everything installed into `libexec` with `gem install --install-dir`;
- `bin` wrapped via `bin.env_script_all_files(libexec/"bin", GEM_HOME: libexec, GEM_PATH: libexec)`, so `portage` always runs with its own gems and never picks up the user's.

**Release flow today:** `rake release_check[gem]` and `rake publish_all` in the root `Rakefile`. The formula must follow rubygems.org releases automatically, or it'll be stale within a week.

**Things that shell out**, which must work from a Homebrew install:
- the Keychain backend (`security`, present on macOS);
- the Secret Service backend (`secret-tool`, on Linux; see open decision 2);
- `open`/`xdg-open` for auto-open;
- `osascript` (the notify plan).

None of these need a Homebrew dependency on macOS.

## Naming

**The formula is `portage`**, the same as the command it installs, which gives the cleanest install line.
- Gentoo's Portage has no Homebrew formula, and its command is `emerge`, so nothing collides in Homebrew.
- If homebrew-core reviewers object to the name later (Phase 5), rename the formula then with Homebrew's `formula_renames.json`, so existing installs keep upgrading.

## Non-negotiable constraints

- **Self-contained.** The formula installs into `libexec` with its own `GEM_HOME`/`GEM_PATH`. It never runs `gem install` into the user's gem home and never needs `sudo`. `brew uninstall` removes everything except `~/.portage/` (user data, which stays).
- **Pinned and verified.** Every gem is a `resource` with an exact version and `sha256` from rubygems.org. No `gem install portage-cli` at install time that resolves versions freshly: that would make installs unreproducible and skip checksum verification.
- **Same binary behaviour as the gem.** No Homebrew-specific code paths in `portage-cli`, apart from what `doctor` reports (install method and Ruby path). `UserAgent` stays `portage-cli/<version> …`. The version comes from the gem, not the formula.
- **Tests run offline.** The formula's `test do` block must pass without network: `portage --version` matching the formula version, plus `portage doctor --offline` (or the nearest existing no-network check). Homebrew CI runs it in a sandbox.
- **`~/.portage` is never touched at install.** Policy, payment methods, transaction logs and the ledger all belong to the user. A formula `post_install` must not create or migrate them.

## Phases

### Phase 1: Tap + formula

- Create the tap repo `tomtom87/homebrew-portage`. The formula is **`portage`** (decided; see Naming). Install becomes:
  ```bash
  brew install tomtom87/portage/portage
  ```
  After `brew tap tomtom87/portage` it's just `brew install portage`.
- **`Formula/portage.rb`** (class `Portage`):
  - `desc` and `homepage` (the repo), `license "MIT"`;
  - `depends_on "ruby"` (Homebrew's current Ruby, ≥ 3.2);
  - one `resource` per gem in the resolved runtime set;
  - `install` runs `gem install --install-dir libexec --no-document --ignore-dependencies` for each resource in dependency order, then `bin.env_script_all_files`;
  - installs the `portage` and `portage-console` commands;
  - `test do` (see constraint).
- **Bundle all first-party adapters** (and `webmcp`, `decision`) by default. They add no new third-party dependencies (see Context).
- **Generating resources:** `script/homebrew-formula` in this repo (Ruby, stdlib only):
  - resolves `portage-cli`'s runtime dependency closure plus the adapter gems at their released versions, using `Gem::Resolver` against rubygems.org;
  - fetches each `.gem`'s `sha256` from the rubygems API;
  - renders the formula from an ERB template.

  No hand-maintained resource list.
- **Native extensions:** check whether any gem in the closure needs a compiler (e.g. `bigdecimal` via `json_schemer`, or `json`). If one does, that's fine without bottles on a machine with Xcode CLT, but it slows installs; Phase 3 fixes that with bottles.
- **Verify:**
  - `brew install --build-from-source ./Formula/portage.rb`
  - `brew test portage`
  - `brew audit --strict --online portage`
  - a real `portage doctor` and `portage buy --dry-run` against a test store
  - macOS arm64 and x86_64, plus Linux Homebrew

### Phase 2: Release automation

- A GitHub Action in this repo, triggered when `portage-cli` is published (a tag like `portage-cli-v*` from `rake publish_all`, or a `workflow_dispatch`):
  1. waits for rubygems.org to serve the new version (poll the API with a bounded retry);
  2. runs `script/homebrew-formula`;
  3. opens a PR against `homebrew-portage` with the new formula;
  4. the tap's own CI (`brew test-bot`) installs and tests it on macOS and Linux before merge.
- Also re-runs when *any* bundled gem releases (an adapter or `portage-ucp`), not only `portage-cli`, so a fix to one adapter reaches brew users.
- Needs a fine-grained token scoped to the tap repo, stored as a secret. No write access to this repo from the tap.
- `rake release_check` gains a warning when the formula template would fail to resolve, e.g. a new dependency that isn't on rubygems yet.

### Phase 3: Bottles

- `brew test-bot` in the tap builds bottles for the supported macOS versions (arm64 and Intel) and for Linux x86_64. `brew pr-pull` publishes them to the tap's GitHub Releases.
- With bottles, `brew install` finishes in seconds with no compiler, which matters if Phase 1 found native extensions.

### Phase 4: Docs + doctor

- README quickstart: `brew install tomtom87/portage/portage` first, `gem install portage-cli` second.
- `docs/cli-usage-tutorial.md` and `docs/getting-started/quickstart.md` get the same order.
- `portage doctor` reports how it was installed (Homebrew when `RbConfig.ruby` or `__dir__` is under `HOMEBREW_PREFIX/Cellar`; otherwise gem), which Ruby it runs, and which adapter gems are loadable. When a Homebrew install finds a second `portage` elsewhere on `PATH`, it warns: a stale `gem install` copy shadowing the brew one is a classic support problem.
- The upgrade path: `brew upgrade portage`, with `~/.portage` untouched.

### Phase 5 (later): homebrew-core

- homebrew-core requires notability (stars, forks, watchers), a stable tagged release, and no self-updating. Revisit after `1.0`. Until then the tap is the supported channel.

## Open decisions

1. ~~Formula name~~: resolved as `portage` (see Naming).
2. **Linux Secret Service:** declare `depends_on "libsecret" => :optional`, or document that `secret-tool` comes from the distro? Leaning towards documenting it, since it's a system D-Bus service anyway.
3. Should the formula offer `--without-adapters` for a minimal install, or is bundling everything always fine? Leaning bundling always, since there are no extra third-party dependencies.
4. Is a MacPorts port also wanted? Out of scope unless requested.

## Explicit non-goals

- No curl-pipe-sh installer.
- No self-update command inside `portage`. Homebrew owns upgrades for brew installs.
- No bundled Ruby build (Homebrew's `ruby` is the dependency). No standalone binary via `ruby-packer` / Tebako in this plan.
- No change to how the gems themselves are built or published.

## Handoff: Phase 1 status and next steps

### Done (this repo)

- **`script/homebrew-formula`** and **`script/templates/portage.rb.erb`**. The script is stdlib-only Ruby and prints the formula to stdout (or writes it with `--out PATH`).
  - Roots are `portage-cli` plus every adapter, `webmcp` and `decision`. First-party gems are pinned to this checkout's `version.rb` and their dependency edges come from the local gemspecs. Third-party gems resolve against rubygems.org to the highest version that satisfies every requester.
  - It aborts if a first-party version isn't published yet. `--latest-published` pins every gem to its newest rubygems.org release instead, which is useful when `main` is ahead of the last release.
  - Only `platform == "ruby"` gems are used. `bigdecimal` and `json` publish a `java` build under the same version number with a different sha256, and picking that one broke checksum verification.
- **`portage --version`** (also `-v` and `version`), which the formula's `test do` needs.
- **`irb` is a runtime dependency of `portage-cli`.** `portage-console` requires it, and from Ruby 4.0 (Homebrew's current `ruby`) it's no longer a default gem, so the console failed with `LoadError` in the formula's isolated `GEM_HOME`. This pulls in `rdoc`, `rbs`, `prism`, `reline` and `io-console`, several of which build native extensions: the resource count goes from 27 to 38 and the install from 6 MB to 27 MB. Phase 3 bottles make this painless.

### Verified (2026-09-25, macOS arm64, Homebrew 6.0.3, Ruby 4.0.7)

- In a local tap (`brew tap-new tomtom87/portage --no-git`), with the formula generated against this branch (unreleased first-party gems built locally and served over `file://`):
  - `brew install --build-from-source` finished in about 30 s;
  - `brew test` passes (`--version` plus offline `doctor --json`);
  - `portage-console` starts.
- With `--latest-published` (0.7.0 on rubygems):
  - `brew style` is clean and `brew audit --strict --online` passes;
  - `brew test` fails only on `--version`, because 0.7.0 predates it.
- **Not verified:** macOS x86_64 and Linux Homebrew, and a real `portage buy --dry-run` against a test store.

### Next, in order

1. **Release first.** Publish seven gems, none of which are on rubygems yet: `portage-ucp` 0.10.0, `portage-ucp-client` 0.6.3, `portage-ucp-webmcp` 0.1.1, `portage-ucp-decision` 0.1.1, `portage-cli` 0.7.3 (with `--version`, `irb` and proxy support), `portage-ucp-shopify` 0.5.1 and `portage-ucp-instagram` 0.1.5. Use `rake publish_all`, which pushes them in dependency order. Core, Shopify and Instagram were first missed: the proxy work changed them without a version bump, so `publish_all` would have skipped core and shipped a CLI that needs `Support::Connection` against a 0.9.0 core without it. Until the release is out, the generator's default mode refuses to run, and a `--latest-published` formula fails `brew test`.
2. **Create the tap** `tomtom87/homebrew-portage`, for example with `brew tap-new tomtom87/portage` and pushing it to GitHub, which also gives the tap `brew test-bot` CI workflows. Then run `script/homebrew-formula --out <tap>/Formula/portage.rb`, commit, and push. Check `brew install tomtom87/portage/portage` from a clean machine or VM, including Intel and Linux.
3. **Phase 2** (release automation) as specified above. The generator's stdout/`--out` interface and its clear "not published yet" error are meant for the Action's poll-then-generate step.
4. **Phase 4 note:** the local install printed Homebrew's own caveat, `portage` is shadowed by a `gem install` copy in the mise Ruby's bin, which is exactly the case the planned `doctor` PATH warning targets.

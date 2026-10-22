---
name: release
description: Cut a Portage release set end to end (gems, GitHub release, Homebrew, ghcr images, MCP Registry, Glama); use for "cut a release", "release set", "ship the gems", "/release".
---

# Release a Portage set

Releases are versioned `X.Y.0` for the whole set (root CHANGELOG, git tag `vX.Y.0`). Only gems that changed get released. Work through the steps in order and report after each one.

## Who does what

- Claude never handles credentials. The user runs `gem push` and `mcp-publisher login github` (device code) themselves.
- Ask before anything outward that wasn't explicitly requested: pushing to the Homebrew tap, `gem push`-adjacent steps, registry publishes, image pushes, GitHub release creation.
- Merge PRs with `--rebase` only.

## 1. Prep on branch `release-X.Y.0`

1. One commit per released gem, titled `Release <gem> <ver> ...`, touching its `lib/.../version.rb` (e.g. `portage-ucp/lib/portage/ucp/version.rb`, `portage-ucp-client/lib/portage/ucp/client/version.rb`, `portage-cli/lib/portage/cli/version.rb`), its `CHANGELOG.md` and its `Gemfile.lock`. See `bbc4f71` for an example.
2. Raise a dependent gem's gemspec range only where resolution requires it. Gems whose ranges already admit the new version stay unreleased.
3. Refresh the version tables and "Latest release set" line in `README.md` and `docs/index.md`.
4. One commit pointing the pins at the new versions: `Dockerfile` (`portage-cli`), `Dockerfile.store` (`portage-ucp`, adapter), `server.json` and `server.store.json` (`version` and the image tag in `identifier`). `server.json`'s `version` must keep rising by semver even though its image tag tracks `portage-cli`, because the registry marks latest by semver.
5. Root `CHANGELOG.md`: add `## [X.Y.0] - <date>` under `[Unreleased]`, with a leading `**Release set:**` bullet listing each gem and version, what changed, and which gems were left alone.
6. Per released gem, from its directory, run `LC_ALL=en_US.UTF-8 bundle exec rspec && bundle exec rubocop`. `portage-cli`'s lock pins `rdoc 8.0.0`; if that isn't installed locally, swap it temporarily and never commit the swap.
7. Push the branch, open a PR (the repo has no CI; local suites are the gate), and once the user approves, merge with `--rebase`. Note the merge sha on `main`.

## 2. Gems (user)

Ask the user to `gem push` in this order: `portage-ucp`, `portage-ucp-client`, `portage-cli`, then any others. Verify each with `gem list -r '^<name>$'`.

## 3. GitHub release

Write `notes.md` in the v0.21.0 style (`gh release view v0.21.0 -R tomtom87/Portage`): intro paragraph, a bullet per released gem, the images and registry entries, and an install line (`brew upgrade tomtom87/portage/portage` / `gem install portage-cli`). Then:

```
gh release create vX.Y.0 -R tomtom87/Portage --target <merge sha> --title vX.Y.0 --latest -F notes.md
```

## 4. Homebrew

The user may already have done this; check first. Otherwise clone `tomtom87/homebrew-portage` into the scratchpad, then run `ruby script/homebrew-formula --out <clone>/Formula/portage.rb`. If the formula changed, commit `portage <ver>` and, after asking, push. Check `brew info tomtom87/portage/portage`.

## 5. ghcr images

Docker Desktop must be running (`open -a Docker`). Run each in the background:

```
docker buildx build --builder portage-builder --platform linux/amd64,linux/arm64 -f Dockerfile -t ghcr.io/tomtom87/portage-mcp:<cli ver> --push .
docker buildx build --builder portage-builder --platform linux/amd64,linux/arm64 -f Dockerfile.store -t ghcr.io/tomtom87/portage-ucp:<ucp ver> --push .
```

Smoke-test the buyer image over stdio: `initialize` (protocol 2025-11-25), `tools/list` (expect 14 tools), `server/discover` (2026-07-28).

## 6. MCP Registry

Run `mcp-publisher validate`, then `mcp-publisher publish` for `server.json` and for `server.store.json`. On a 401 (expired token), tell the user to run `mcp-publisher login github`; never do it for them.

## 7. Glama

Use Claude in Chrome (the user is logged in). Glama does not use our `Dockerfile`.

1. Open `glama.ai/mcp/servers/tomtom87/Portage/admin/dockerfile`. Edit the Build steps code editor so it reads `gem install --no-document portage-cli:<ver>`. It is a div, not a textarea: click the line, press End, use the arrow keys, retype.
2. Open `admin/repository` and press Sync Server until the head commit equals the merge sha.
3. Glama's Auto-Release builds a release named after the GitHub tag. Do not press Build & Release: it creates a stray extra release.
4. On `admin/releases`, confirm the build test log shows the new commit, the new `portage-cli` version and the new `serverInfo` version.

## Finish

Report what shipped and anything not verified (for example, a step the user did themselves).

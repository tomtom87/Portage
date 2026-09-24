## Development

Each gem manages its own tests/lint independently — its own `Gemfile`/`Gemfile.lock`, own `spec/`, no shared state or run-order dependency between gems:

```bash
cd portage-ucp && bundle exec rspec && bundle exec rubocop
```

Or run the full suite across every gem in one command, via the root `Rakefile` — it just shells into each gem dir in turn and stops at the first failure, no root-level bundle or cross-gem dependency involved:

```bash
rake spec   # == rake, spec is the default task
```

See the [design log](docs/design-log.md) for the rationale and decision history behind this project.

### Releasing a gem

`gem build` must be run from inside the gem's own directory, not the workspace root — every gemspec's `spec.files = Dir["lib/**/*.rb", ...]` resolves against whatever the current directory is, so building from the wrong place silently produces an empty package (see the 0.7.1 postmortem in the [changelog](CHANGELOG.md)). Before pushing a build, run it through `release_check`, which builds the gem from its own directory and smoke-tests that the resulting package actually installs and `require`s:

```bash
rake release_check[portage-ucp]
```

Only push to RubyGems once that passes.

#!/usr/bin/env bash
# Adds portage-ucp (+ optionally a platform adapter gem) to the host app's
# Gemfile and wires up the initializer — via the Rails generator
# (lib/generators/portage/ucp/install) when Rails is present, or by copying
# the same template directly otherwise. Idempotent: re-running skips steps
# already done rather than clobbering hand-edited files.
set -euo pipefail

ADAPTER_GEM="${1:-}"

if [ ! -f "Gemfile" ]; then
  echo "No Gemfile here — run this from your app's root." >&2
  exit 1
fi

if ! grep -q '^\s*gem ["'\'']portage-ucp["'\'']' Gemfile 2>/dev/null; then
  echo "Adding portage-ucp to Gemfile..."
  bundle add portage-ucp
else
  echo "portage-ucp already in Gemfile — skipping."
fi

if [ -n "$ADAPTER_GEM" ] && ! grep -q "gem [\"']${ADAPTER_GEM}[\"']" Gemfile 2>/dev/null; then
  echo "Adding ${ADAPTER_GEM} to Gemfile..."
  bundle add "$ADAPTER_GEM"
fi

if [ -f "config/initializers/portage_ucp.rb" ]; then
  echo "config/initializers/portage_ucp.rb already exists — leaving it alone."
elif grep -q '^\s*gem ["'\'']rails["'\'']' Gemfile 2>/dev/null; then
  echo "Rails detected — running the install generator..."
  bundle exec rails generate portage:ucp:install
else
  echo "No Rails — writing a standalone initializer stub instead."
  mkdir -p config/initializers
  bundle exec ruby -e '
    require "portage/ucp"
    template = Gem.loaded_specs["portage-ucp"].gem_dir +
      "/lib/generators/portage/ucp/install/templates/portage_ucp.rb"
    FileUtils.mkdir_p("config/initializers")
    FileUtils.cp(template, "config/initializers/portage_ucp.rb")
    puts "Wrote config/initializers/portage_ucp.rb — require it explicitly at boot"
    puts "(no Rails autoloading here): require \"./config/initializers/portage_ucp\""
  '
fi

echo
echo "Next: fill in config/initializers/portage_ucp.rb (authenticator, rate_limiter,"
echo "business, signing_keys — every TODO in that file), write your Adapter subclass"
echo "if you haven't (\`portage generate adapter Foo\` scaffolds one), then run"
echo "doctor.sh before declaring this done."

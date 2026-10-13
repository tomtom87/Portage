#!/usr/bin/env bash
# Thin wrapper around `portage doctor` (portage-cli) — sanity-checks whatever
# config/initializers/portage_ucp.rb configured, since a Rails app doesn't
# boot that file until config/environment is loaded.
set -euo pipefail

REQUIRE_FILE="${1:-config/environment}"
ADAPTER_CLASS="${2:-}"

if ! bundle show portage-cli > /dev/null 2>&1; then
  echo "portage-cli isn't in this app's bundle — add it (\`bundle add portage-cli\`," >&2
  echo "development group is fine) to run doctor from inside this app." >&2
  exit 1
fi

args=(doctor --require "./${REQUIRE_FILE}")
[ -n "$ADAPTER_CLASS" ] && args+=(--adapter "$ADAPTER_CLASS")

bundle exec portage "${args[@]}"

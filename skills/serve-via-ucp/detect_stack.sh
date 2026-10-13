#!/usr/bin/env bash
# Detects what kind of Ruby app this is and what's already installed, so
# install.sh knows whether to run the Rails generator or fall back to a
# plain initializer file. Never mutates anything — read-only reconnaissance.
set -euo pipefail

echo "== serve-via-ucp: stack detection =="

if [ -f "Gemfile" ]; then
  echo "Gemfile: found"
else
  echo "Gemfile: NOT FOUND — run this from your Rack/Rails app's root."
  exit 1
fi

if grep -q '^\s*gem ["'\'']rails["'\'']' Gemfile 2>/dev/null; then
  echo "framework: Rails"
else
  echo "framework: plain Rack (no Rails gem in Gemfile) — install.sh writes a"
  echo "  standalone initializer instead of running a Rails generator."
fi

for gem_name in portage-ucp portage-ucp-shopify portage-ucp-wix portage-ucp-woocommerce \
                portage-ucp-bigcommerce portage-ucp-magento portage-ucp-etsy portage-ucp-instagram; do
  if [ -f "Gemfile.lock" ] && grep -q "^    ${gem_name} " Gemfile.lock 2>/dev/null; then
    version=$(grep "^    ${gem_name} " Gemfile.lock | head -1 | tr -d '()' | awk '{print $2}')
    echo "gem: ${gem_name} ${version} (already in Gemfile.lock)"
  fi
done

if [ -f "config/initializers/portage_ucp.rb" ]; then
  echo "initializer: config/initializers/portage_ucp.rb already exists"
fi

if grep -rl "Portage::Ucp::Adapter" --include="*.rb" app lib 2>/dev/null | grep -v "_spec.rb" | head -1 > /dev/null; then
  echo "adapter: found a Portage::Ucp::Adapter subclass —"
  grep -rl "Portage::Ucp::Adapter" --include="*.rb" app lib 2>/dev/null | grep -v "_spec.rb" | sed 's/^/  /'
else
  echo "adapter: none found yet — you'll need to write one (see portage-ucp's README,"
  echo "  \"Writing your own adapter\")."
fi

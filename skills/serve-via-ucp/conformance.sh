#!/usr/bin/env bash
# Runs the shipped RSpec conformance kit (portage-ucp/lib/portage/ucp/rspec.rb,
# "a portage adapter") against the consumer's own Adapter spec. Doesn't write
# the spec file for them — every adapter's fixture data (existing_product_id,
# stubbed HTTP responses) is backend-specific — but fails loudly if one
# doesn't exist yet, same rationale as the repo's own `rake conformance` gate.
set -euo pipefail

SPEC_PATH="${1:-spec}"

if ! grep -rl 'it_behaves_like "a portage adapter"' --include="*_spec.rb" spec 2>/dev/null | head -1 > /dev/null; then
  cat >&2 <<'EOF'
No spec includes "a portage adapter" yet. Add one, e.g.:

  require "portage/ucp/rspec"

  RSpec.describe YourAdapter do
    let(:adapter) { described_class.new(...) }
    let(:existing_product_id) { "a real, in-stock, purchasable id in your test backend" }

    it_behaves_like "a portage adapter"
  end

See portage-ucp-etsy/spec/.../conformance_spec.rb in the Portage repo for a
worked example, including how to stub just enough HTTP for a partial adapter.
EOF
  exit 1
fi

bundle exec rspec "$SPEC_PATH"

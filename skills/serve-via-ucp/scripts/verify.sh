#!/usr/bin/env bash
# Curls a running server's /.well-known/ucp and sanity-checks the JSON shape
# — this does NOT boot the server itself (too stack-specific to guess);
# start it however this app normally starts, then run this against it.
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
URL="${BASE_URL%/}/.well-known/ucp"

echo "GET ${URL}"
body="$(curl -fsS "$URL")" || {
  echo "Request failed — is the server running at ${BASE_URL}?" >&2
  exit 1
}

echo "$body" | ruby -rjson -e '
  payload = JSON.parse(STDIN.read)
  ucp = payload["ucp"]

  unless ucp.is_a?(Hash)
    warn "Manifest has no top-level \"ucp\" object — live UCP stores nest everything under it."
    exit 1
  end

  required = %w[version business services capabilities]
  missing = required - ucp.keys
  unless missing.empty?
    warn "Missing required manifest key(s) under \"ucp\": #{missing.join(", ")}"
    exit 1
  end

  caps = ucp["capabilities"] || {}
  puts "version: #{ucp["version"]}"
  puts "capabilities advertised: #{caps.keys.join(", ")}"
  puts "signed: #{ucp.key?("signature")}"

  if caps.empty?
    warn "No capabilities advertised at all — check your Adapter overrides at least one method."
    exit 1
  end
'

echo "OK — manifest looks well-formed."

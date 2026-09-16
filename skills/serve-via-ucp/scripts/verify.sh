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
  required = %w[ucp_version business services capabilities]
  missing = required - payload.keys
  unless missing.empty?
    warn "Missing required manifest key(s): #{missing.join(", ")}"
    exit 1
  end

  caps = payload["capabilities"] || []
  puts "ucp_version: #{payload["ucp_version"]}"
  puts "capabilities advertised: #{caps.map { |c| c["name"] }.join(", ")}"
  puts "signed: #{payload.key?("signature")}"

  if caps.empty?
    warn "No capabilities advertised at all — check your Adapter overrides at least one method."
    exit 1
  end
'

echo "OK — manifest looks well-formed."

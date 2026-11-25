# Spec conformance

`Portage::Ucp::SchemaValidator` validates data against UCP's own vendored JSON Schemas/OpenRPC docs offline (no network calls, no reliance on ucpchecker.com as a CI gate) — useful in your own test suite if you want to assert your adapter's output is schema-conformant beyond what `to_wire_h` already guarantees.

See [Writing adapters](writing-adapters.md#checking-your-adapter-against-the-contract) for
the RSpec conformance kit that layers behavioral checks (idempotency, PAN rejection) on top
of schema validity.

## Client transports

`portage-ucp-client` speaks both of the 2026-08-25 transports it can reach: MCP and REST. The REST routes are the `operationId`s in `https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json`, which match the MCP tool names. Response signatures (`Signature`/`Content-Digest`) are not verified on either transport. `portage-ucp` stores still serve MCP only; a Rack REST endpoint for stores is not built. The `ask` capability (`dev.ucp.common.ask`) is called on both transports (`ask_business`, `POST /ask` with the bare request body), only when the store advertises it, and the answer is handled as untrusted text. Identity-linked ask (`dev.ucp.common.ask:read`) is not supported. A2A and embedded are not supported.

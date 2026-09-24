# Spec conformance

`Portage::Ucp::SchemaValidator` validates data against UCP's own vendored JSON Schemas/OpenRPC docs offline (no network calls, no reliance on ucpchecker.com as a CI gate) — useful in your own test suite if you want to assert your adapter's output is schema-conformant beyond what `to_wire_h` already guarantees.

See [Writing adapters](writing-adapters.md#checking-your-adapter-against-the-contract) for
the RSpec conformance kit that layers behavioral checks (idempotency, PAN rejection) on top
of schema validity.

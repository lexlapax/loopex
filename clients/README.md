# Clients

Independent consumers of the Loopex experimental public session protocol,
written in languages other than Elixir. They exist to prove that the protocol
is a byte contract rather than an Elixir interface: each one speaks the wire
and reaches nothing inside a runtime.

A client here is not shipped, supported or versioned as a product. It is
evidence, and it is written to be read by someone implementing their own.

| Directory | Language | What it is |
| --- | --- | --- |
| [node](node/README.md) | JavaScript on Node | A client library and the integrated workflow that drives a real server process |

The protocol these speak is defined by
[ADR 0023](../docs/adr/0023-experimental-public-session-protocol.md) and its
[technical companion](../docs/adr/0023-experimental-public-session-protocol-technical.md).
The conformance vectors an implementation checks itself against live in
`apps/loopex_protocol/test/public_schema_conformance_test.exs`.

Back to the [repository README](../README.md).

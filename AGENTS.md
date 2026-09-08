# JournalAsh Agent Rules

1. This is a public, application-neutral library. Never add application data,
   client names, secrets, private paths, or host-specific policy.
2. Application and library callers keep using Elixir's `Logger` API. Do not add
   a parallel `JournalAsh.log` facade or require call-site sink selection.
3. Producers describe an event; `JournalAsh.Policy` alone decides retention and
   projections. Ignore producer-supplied routing and retention metadata.
4. Logger intake must remain bounded and non-blocking. Do not replace the ETS
   fixed-slot queue and single server-owned tick with an unbounded process
   mailbox, producer wake handshake, or persistence in a Logger filter.
5. Journal internals, stores, and emergency handling must not call `Logger`.
   Recursion fallback writes only a fixed, sanitized message to stderr.
6. Logger observations and transaction-linked Ash facts have different
   guarantees. Never claim that an observation proves a database commit.
7. Current Ash resource state is authoritative. JournalAsh does not rebuild
   application state by replaying history.
8. A committed-fact integration must write through an Ash action inside the same
   data-layer transaction, fail closed, and explicitly support or reject bulk and
   atomic paths. Do not ship a best-effort approximation.
9. Storage is application-owned. Production adapters must be bounded,
   idempotent by entry ID, authorization-aware, and explicit about durability.
10. Prefer model and property tests. This library has no UI and needs no browser
    test suite.

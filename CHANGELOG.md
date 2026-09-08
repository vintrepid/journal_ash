# Changelog

## 0.1.0-alpha.2 — Unreleased

- Add a bounded, versioned `JournalAsh.SealedEntry` codec backed by a host-owned
  Cloak vault.
- Encrypt every canonical entry field except the clear format, version, and UUID
  required for storage compatibility and idempotency.
- Document that the default memory store remains plaintext and that server-side
  encryption at rest is neither redaction nor client-held-key end-to-end privacy.

## 0.1.0-alpha.1

- Establish a bounded OTP Logger primary-filter intake with fail-open output.
- Add journal-owned retention and projection decisions.
- Add an embedded Ash entry contract and volatile memory adapter.
- Separate Logger observations from transaction-linked committed facts.
- Add health and flush operations.

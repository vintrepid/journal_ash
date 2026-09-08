# Security Policy

## Supported versions

JournalAsh is currently an alpha. Security fixes are applied to the latest
alpha release and the `main` branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for the `journal_ash`
repository. Do not open a public issue containing an exploit, credentials,
private log data, or customer information.

Include the affected version, impact, minimal reproduction, and any suggested
mitigation. Remove real secrets and personal data from reproductions.

## Security model

JournalAsh treats every Logger event as untrusted input. On its journal path:

- atomic fixed-slot intake is bounded before persistence;
- strings, total retained binary bytes, maps, nesting, nodes, and collections
  are bounded;
- arbitrary values are never inspected during normalization;
- metadata is allowlisted by default; optional `:all` capture rejects unsafe
  keys and redacts common credential-shaped fields;
- producer metadata cannot select retention or output sinks;
- emergency output is fixed text and never includes the rejected event;
- emergency reporting has one bounded pending slot and never writes from the
  Logger caller;
- persistence work in the intake process is protected against Logger recursion.

The primary filter does not sanitize conventional Logger output. On a standard
output decision it returns the original host event unchanged, and on
normalization or intake failure it deliberately fails open. Existing text/JSON
handlers can therefore emit everything the application originally logged.

These protections are data minimization, not a secret-detection guarantee.
Applications must not place credentials, document bodies, private messages, or
other sensitive payloads in log messages. Report-map and format-argument capture
is disabled by default.

The configured policy executes synchronously in the Logger caller and must be
fast, bounded, deterministic, and side-effect free. Library-owned normalization
caps the combined message and captured-metadata payload at 32 KiB and captured
metadata at 64 retained nodes. Queue capacity is capped at 4,096, for a maximum
cross-product of 128 MiB of payload binaries. Separately bounded identity, event,
decision, and timestamp fields are additional. Actual BEAM memory is higher
because maps, lists, processes, and temporary validated entries have structural
overhead. Source paths are excluded by default; opting into `:file` metadata or
`:all` capture can disclose absolute build and user-directory paths.

The recursion marker is process-local. Store callbacks and every process to
which they delegate must not call `Logger`; otherwise those calls look like new
observations and can recursively enter JournalAsh. Store adapters must report
failures through callback results and health data. Telemetry handlers execute in
the intake process and must remain fast and non-blocking.

The bundled memory store is volatile and intended only for tests and local
evaluation. It provides neither durable retention nor encryption at rest.

## Dependency-audit acknowledgement

The Hex advisory record for `EEF-CVE-2026-32686` currently marks every Decimal
version as affected, while the [EEF CNA](https://cna.erlef.org/cves/CVE-2026-32686.html)
and [Decimal's upstream advisory](https://github.com/ericmj/decimal/security/advisories/GHSA-rhv4-8758-jx7v)
identify 3.0.0 as the fixed release. JournalAsh therefore requires Decimal 3.x and
narrowly acknowledges that advisory ID so `mix hex.audit` remains useful for
all other findings. Remove the acknowledgement when Hex corrects its feed.

# JournalAsh

JournalAsh is a bounded activity journal and OTP Logger integration for Ash
applications.

Application code continues to call `Logger.debug/2`, `Logger.info/2`, and the
other standard Logger functions. It describes what happened; it does not choose
whether an event is retained, printed, or sent to telemetry. JournalAsh owns
that policy centrally.

## Status

`0.1.0-alpha.2` is a tested foundation, not a production journal backend. It
currently provides:

- an OTP Logger primary filter that accepts existing Logger events;
- a fixed-capacity ETS intake queue with atomic, bounded slot admission;
- bounded normalization, metadata allowlisting, and common-secret redaction;
- central retention and projection decisions;
- global conventional-output control without adding internal event metadata;
- a message-free telemetry projection selected by the same policy;
- a canonical embedded Ash observation resource;
- a bounded, versioned Cloak codec that ciphertext stores can use to seal the
  complete canonical entry with a host-owned vault;
- a bounded, idempotent, volatile memory store for tests and local evaluation;
- process-local recursion protection, sanitized emergency output, health, and
  graceful flush;
- a separate typed boundary for future transaction-linked Ash facts.

It does **not** yet provide a durable Ash/Postgres store, migrations, history
queries, an Igniter installer, encrypted journal storage, or the transactional
Ash resource extension described below. Do not use the bundled memory adapter as
a production audit trail.

All interfaces are intentionally pre-1.0 and may change between alphas. The
compatibility target today is existing `Logger` call sites and canonical Ash
resource boundaries—not preservation of an early Journal API that prevents a safer
design.

## The model

```text
existing Logger call
       |
       v
OTP primary filter -- normalize + policy --+--> bounded queue --> journal store
                                            |
                                            +--> unchanged event or global stop
                                                 for conventional handlers

future Ash mutation
       |
       +-- same-transaction change --> committed fact store
```

A Logger entry is an **observation**: a process asked Logger to emit it. It does
not prove that an associated database transaction committed.

A **committed fact** must be inserted by a future JournalAsh Ash extension inside
the same data-layer transaction as the resource mutation. Fact insertion must
fail closed and roll back that mutation. Version 0.1 defines the type boundary
but deliberately does not expose an ingest function that could fake this
guarantee.

Current Ash resources remain authoritative. JournalAsh is not event sourcing and
does not reconstruct application state by replaying entries. Reversals and undo
should be new, valid domain actions linked to the original fact.

## Installation

Until the first Hex release, use the Git repository:

```elixir
def deps do
  [
    {:journal_ash, github: "vintrepid/journal_ash", tag: "v0.1.0-alpha.2"}
  ]
end
```

JournalAsh requires Ash 3.33 or later. Its OTP dependency remains `:ash`, and
the same suite is exercised against upstream Ash and AshLotus's
upstream-tracking `ash_lotus_core` fork.

Ash 3.33 and later requires a string-length counting policy in the host config:

```elixir
config :ash, default_string_length_count: :codepoints
```

## Existing Logger calls

No JournalAsh logging facade is needed:

```elixir
Logger.info("task completed",
  event: "workflow.task.completed",
  request_id: request_id
)
```

Use a stable, lowercase event name. Metadata is data, not policy. Values such as
`journal?: true`, `text?: false`, or `retention: :forever` are intentionally not
accepted from producers.

Logger's compile-time, primary-level, and preceding primary-filter decisions still
apply. JournalAsh runs last among primary filters, so process-level suppression
and host redaction happen before journal capture. An event stopped there cannot
reach JournalAsh or any Logger handler.

## Configuration

JournalAsh starts with conservative migration behavior: retain every accepted
observation and preserve conventional Logger output.

```elixir
config :journal_ash,
  capacity: 1_024,
  batch_size: 100,
  retry_interval: 100,
  max_entry_attempts: 5,
  sweep_interval: 100,
  recent_drop_window: 60_000,
  policy: MyApp.JournalPolicy,
  store: {MyApp.JournalStore, []},
  logger_filter_id: :journal_ash,
  metadata_keys: [
    :event,
    :request_id,
    :trace_id,
    :span_id,
    :module,
    :function,
    :line
  ]
```

The primary filter runs after host primary filters and before every OTP Logger
handler, so the `:standard_log` decision is global. On successful journal
admission it returns the event it received unchanged or stops conventional output. It never attaches
private routing markers that an unmanaged JSON handler could expose. If
normalization or intake fails, output fails open and the original Logger event
continues to conventional handlers. Startup fails on a `logger_filter_id`
collision. Uninstall deactivates JournalAsh's runtime while leaving its stable
filter inert; it never removes a host replacement by identifier. Restart can
reuse that filter after its former owner exits.

Configure primary filters before JournalAsh starts. OTP has no atomic append
operation, so initial placement reads and replaces the filter list; concurrent
host reconfiguration during installation is unsupported. Later
`:logger.add_primary_filter/2` calls prepend, preserving JournalAsh's position.
Directly replacing the filter list can move JournalAsh out of order; health
reports `primary_filter_order: :not_last` in that case.

This alpha requires the primary `filter_default` to be `:log` and rejects
installation when it is `:stop`. The last filter cannot distinguish an earlier
explicit logging decision from all earlier filters ignoring the event. Keep
that default while JournalAsh is active; health exposes
`primary_filter_default` and degrades if it changes. Inactive, stale, and
failure paths return OTP's `:ignore`, preserving the host's decision and
default behavior.

The configured policy implements `JournalAsh.Policy`:

```elixir
defmodule MyApp.JournalPolicy do
  @behaviour JournalAsh.Policy

  alias JournalAsh.Decision

  @impl true
  def decide(envelope, _options) do
    projections = if envelope.level == :debug, do: [], else: [:standard_log]

    %Decision{
      retention: :retain,
      projections: projections,
      reason: :application_policy
    }
  end
end
```

Policy runs once, synchronously, in the process making the Logger call. It must
therefore be deterministic, fast, bounded, and side-effect free. JournalAsh
falls back to retention plus conventional output if it raises or returns an
invalid decision.

Report maps and format arguments are omitted by default. They may be captured as
bounded, sanitized data with `capture_reports: true`, but applications should
prefer small allowlisted metadata.

## Operations

```elixir
JournalAsh.health()
JournalAsh.flush(5_000)
```

These functions use the configuration captured when the application started.
Configuration changes take effect on restart. When the application is stopped,
health reports `:unavailable` and flush returns
`{:error, :application_not_running}`.

Health reports queue depth and utilization, capacity, accepted/rejected counts,
admission losses, store health, waiting flush callers, and Logger-filter
presence. It becomes `:degraded` at 80% queue utilization and remains degraded
for the bounded `recent_drop_window` after an admission loss, even if the queue
has already drained. `last_admission_drop_age_ms` and the cumulative
`admission_dropped` count preserve the reason for that status. Drop accounting
uses only fixed atomics with a bounded timestamp update; it sends no producer
message to the intake process. `flush/1` asks the intake to drain completely and
then flushes the configured store. Logging that continually adds observations
can extend that drain, so the operation returns `{:error, :timeout}` rather than
claiming a sequence-watermark guarantee.

Flush accepts a timeout from 1 to 60,000 milliseconds. At most 64 calls may be
outstanding, including calls waiting behind a blocked store callback; further
calls return `{:error, :too_many_waiters}`. A caller timeout does not free its
admission slot until the consumer acknowledges the request. This bounds the
consumer's flush mailbox even when callers repeatedly time out. Successful
flush includes an empty-queue check after the store flush; new observations can
of course arrive immediately afterward.

Logger observations remain best-effort under VM death, an unavailable store, or
sustained overload. Admission probes at most 32 fixed slots; if it cannot claim
one, it conservatively drops the journal copy as `:full` or `:slot_busy`, keeps
conventional output, and queues at most one fixed, rate-limited stderr warning.
The warning is emitted by a supervised process, never the Logger caller. A
future durable spool can strengthen this guarantee without changing Logger call
sites.

Host configuration cannot raise the combined message and captured-metadata
payload above 32 KiB or queue capacity above 4,096. Their hard cross-product is
128 MiB of payload binaries. Separately bounded identity, event, decision, and
timestamp fields are additional; actual BEAM memory is higher because terms and
temporary Ash entries have structural overhead. Defaults are 32 KiB and 1,024
entries.

## Store adapters

A store implements `JournalAsh.Store`. `append/2` runs in the consumer, not the
Logger caller, and must be idempotent by entry ID because acknowledgements may be
retried.

`append/2` returns `:ok`, `{:error, {:retryable, reason}}`, or
`{:error, {:permanent, reason}}`. Retryable failures allow other queued entries
to proceed and are limited by `max_entry_attempts` (default 5, hard maximum
100). Exceptions are retryable; permanent failures and undocumented return
shapes drop that observation immediately. Exhausting the attempts also drops
the observation. Health exposes `retryable_failures`, `permanent_failures`,
`retry_exhausted`, and `terminal_dropped`. Recent terminal loss keeps health
degraded for the same bounded `recent_drop_window`, with
`last_terminal_drop_age_ms` exposing its age. A flush that observes terminal loss
returns `{:error, :entries_dropped}`; a later successful flush does not certify
that earlier observations were retained.

Store callbacks and any process to which they delegate must not call `Logger`.
The recursion marker protects work performed in the intake process; it cannot
mark a separate store process. Adapters return errors from their callbacks and
surface details through `health/1` instead.

Telemetry handlers execute synchronously in the intake process. They must also
remain fast and non-blocking. Telemetry callbacks receive only operational
identities, never the free-form message or arbitrary metadata. Delivery is
best-effort and has no exactly-once guarantee. Each projection includes the
stable observation `:id`; handlers with non-idempotent side effects should use
it to deduplicate an envelope that is admitted more than once.

The physical production resource belongs to the host application so its Ash
domain, repository, tenancy, authorization, encryption, migrations, and
retention policy remain explicit. The planned JournalAsh extension will generate
that contract rather than silently choosing a database.

### Cloak-sealed entries

JournalAsh depends directly on Cloak and exposes `JournalAsh.SealedEntry` as the
encryption boundary for store adapters. It encrypts the complete, already
validated `JournalAsh.Entry`; only a versioned format marker and the entry UUID
remain clear. The clear UUID is deliberate so a store can preserve JournalAsh's
idempotency contract across retries.

The application defines, configures, and supervises its own vault:

```elixir
defmodule MyApp.JournalVault do
  use Cloak.Vault, otp_app: :my_app

  @impl GenServer
  def init(config) do
    key =
      "JOURNAL_VAULT_KEY_BASE64"
      |> System.fetch_env!()
      |> Base.decode64!()

    {:ok,
     Keyword.put(config, :ciphers,
       default: {Cloak.Ciphers.AES.GCM, tag: "JOURNAL.AES.GCM.V1", key: key}
     )}
  end
end
```

Use an authenticated cipher such as AES-GCM. Cloak allows arbitrary host
ciphers; JournalAsh can validate the interface and returned data shapes but
cannot prove that an arbitrary cipher is confidential or tamper-resistant.
Cipher tags allow the host to retain older decrypting keys while a new default
key writes new values.

A ciphertext store seals before persistence and never substitutes the original
entry when sealing fails:

```elixir
with {:ok, sealed} <- JournalAsh.SealedEntry.seal(entry, MyApp.JournalVault) do
  MyApp.CiphertextJournal.insert(JournalAsh.SealedEntry.to_map(sealed))
end
```

`open/2` accepts the sealed value or its exact JSON-decoded map and returns a
revalidated `JournalAsh.Entry`. Both encoding and decoding have fixed limits;
the JSON plaintext is capped at 256 KiB and its URL-safe Base64 ciphertext at
approximately 343 KiB. Errors are stable atoms and never contain the entry,
ciphertext, key material, or the original Cloak exception.

The codec does not start the vault. An adapter used during JournalAsh startup
must make the vault ready in its own supervised store tree or an earlier OTP
application; the host application's top-level supervisor starts after its
dependencies and is too late for guaranteed capture of startup observations.

This feature is optional and does not change `JournalAsh.Store.Memory`, which
continues to retain plaintext in volatile memory. Adding the dependency alone
does not encrypt existing logs or stores, and JournalAsh intentionally supplies
no plaintext fallback for an encryption-required adapter.

## Privacy

Journal normalization never calls `inspect/2` on arbitrary values. It bounds
strings, aggregate retained binary bytes, metadata entries, collection sizes,
nodes, and nesting, and redacts common credential keys. Producer-supplied
policy and routing keys are ignored.

Source file paths are excluded from the default metadata allowlist. Explicitly
including `:file` or enabling `metadata_keys: :all` can retain absolute build and
user-directory paths.

This sanitization applies to the journal envelope, not to conventional Logger
output: the primary filter deliberately returns the host's original event
unchanged. It is not a content-level secret scanner. A password embedded in the
free-form message string still looks like ordinary text. Do not log credentials,
message or document bodies, authorization headers, provider payloads, or private
Solid data. See [SECURITY.md](SECURITY.md) for the reporting and threat model.

Sanitization and encryption solve different problems. Sanitization removes or
bounds selected values before retention. Cloak encryption is reversible storage
protection for whatever remains. The application server and its configured vault
can decrypt it, and plaintext necessarily exists in the Logger caller, bounded
intake, and encryption process. This is not client-held-key end-to-end encryption
and does not provide Proton- or Signal-style privacy from the service itself.

## Development

```sh
mix deps.get
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix hex.build
```

Compatibility checks can point the same suite at a local or Git Ash-compatible
fork without changing package source:

```sh
JOURNAL_ASH_ASH_PATH=../forks/ash_lotus_core mix test
JOURNAL_ASH_ASH_GIT=https://github.com/vintrepid/ash_lotus_core.git \
  JOURNAL_ASH_ASH_REF=88c3fb4243de5c166ca1a71191bf10f5222813d1 mix test
```

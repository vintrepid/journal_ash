defmodule JournalAsh.Store do
  @moduledoc """
  Behaviour implemented by journal retention adapters.

  Calls happen in the journal consumer process, never in the process emitting a
  Logger event. Adapters must make `append/2` idempotent by entry ID because a
  failed acknowledgement may be retried.

  `append/2` failures are explicit. A retryable failure is attempted again only
  up to the configured per-entry limit. A permanent failure is terminal
  immediately. Returning an undocumented shape is also terminal; it cannot pin
  the queue indefinitely.

  Store callbacks and processes to which they delegate must not call `Logger`.
  JournalAsh's recursion marker is process-local; logging from a separate store
  process would be a new observation and could feed the journal recursively.
  Every callback must also have bounded, predictable latency: `append/2` and
  `health/1` run synchronously in the sole intake consumer, while `flush/1` can
  delay callers and application shutdown. Adapters should expose failures
  through callback results and `health/1`.
  """

  alias JournalAsh.Entry

  @type options :: keyword()
  @type append_result ::
          :ok | {:error, {:retryable, term()}} | {:error, {:permanent, term()}}

  @callback child_spec(options()) :: Supervisor.child_spec()
  @callback append(Entry.t(), options()) :: append_result()
  @callback flush(options()) :: :ok | {:error, term()}
  @callback health(options()) :: map()
end

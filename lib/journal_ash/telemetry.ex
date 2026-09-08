defmodule JournalAsh.Telemetry do
  @moduledoc """
  Safe telemetry projection for accepted observations.

  The projection contains operational identities only; it never includes the
  free-form message or arbitrary observation metadata. Delivery is best-effort
  and not exactly once. Consumers can use the stable observation `:id` to make
  side effects idempotent when an envelope is admitted more than once.
  """

  alias JournalAsh.{Decision, Envelope}

  @event [:journal_ash, :observation]

  @spec emit(Envelope.t(), Decision.t()) :: :ok
  def emit(%Envelope{} = envelope, %Decision{} = decision) do
    if Decision.project?(decision, :telemetry) do
      :telemetry.execute(
        @event,
        %{count: 1},
        %{
          event: envelope.event,
          id: envelope.id,
          kind: envelope.kind,
          level: envelope.level,
          retention: decision.retention,
          source: envelope.source
        }
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Returns the telemetry event name used for observation projections."
  @spec event() :: [atom()]
  def event, do: @event
end

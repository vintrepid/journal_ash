defmodule JournalAsh.Emergency do
  @moduledoc false

  @spec report(atom()) :: :ok
  def report(reason) do
    JournalAsh.EmergencyLimiter.enqueue(reason)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec fixed_message(atom()) :: String.t()
  def fixed_message(:full), do: "journal_ash intake full; an observation was not retained\n"

  def fixed_message(:unavailable),
    do: "journal_ash intake unavailable; an observation was not retained\n"

  def fixed_message(:invalid_logger_event),
    do: "journal_ash rejected a malformed Logger event\n"

  def fixed_message(:slot_busy),
    do: "journal_ash intake busy; an observation was not retained\n"

  def fixed_message(_reason), do: "journal_ash could not retain a Logger observation\n"
end

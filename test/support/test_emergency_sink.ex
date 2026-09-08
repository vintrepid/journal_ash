defmodule JournalAsh.TestEmergencySink do
  @moduledoc false

  def emit(reason, {:raise, receiver}) do
    send(receiver, {:journal_ash_emergency_raise, reason})
    raise "test emergency sink failure"
  end

  def emit(reason, receiver) when is_pid(receiver) do
    send(receiver, {:journal_ash_emergency_started, reason, self()})

    receive do
      :release_journal_ash_emergency -> :ok
    end
  end
end

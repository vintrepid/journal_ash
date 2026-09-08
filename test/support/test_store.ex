defmodule JournalAsh.TestStore do
  @moduledoc false

  use Agent

  @behaviour JournalAsh.Store

  def start_link(options) do
    Agent.start_link(
      fn ->
        %{
          mode: Keyword.get(options, :mode, :ok),
          entries: [],
          attempts: 0,
          attempts_by_id: %{},
          flush_attempts: 0
        }
      end,
      name: Keyword.fetch!(options, :name)
    )
  end

  @impl true
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :name)},
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @impl true
  def append(entry, options) do
    name = Keyword.fetch!(options, :name)

    Agent.update(name, fn state ->
      state
      |> Map.update!(:attempts, &(&1 + 1))
      |> update_in([:attempts_by_id, entry.id], &((&1 || 0) + 1))
    end)

    case Agent.get(name, &append_mode(&1.mode, entry)) do
      :ok ->
        Agent.update(name, &update_in(&1.entries, fn entries -> [entry | entries] end))
        :ok

      :retryable ->
        {:error, {:retryable, :unavailable}}

      :permanent ->
        {:error, {:permanent, :rejected}}

      :invalid ->
        :undocumented_store_result

      {:sleep, milliseconds} ->
        Process.sleep(milliseconds)
        {:error, {:retryable, :unavailable}}
    end
  end

  @impl true
  def flush(options) do
    name = Keyword.fetch!(options, :name)

    {mode, attempt} =
      Agent.get_and_update(name, fn state ->
        attempt = state.flush_attempts + 1
        {{state.mode, attempt}, %{state | flush_attempts: attempt}}
      end)

    case mode do
      :error ->
        {:error, :unavailable}

      {:sleep, _milliseconds} ->
        {:error, :unavailable}

      {:block_first_flush, receiver} when attempt == 1 ->
        send(receiver, {:journal_ash_test_flush_started, self()})

        receive do
          :release_journal_ash_test_flush -> :ok
        end

      _ready ->
        :ok
    end
  end

  @impl true
  def health(options) do
    state = Agent.get(Keyword.fetch!(options, :name), & &1)
    status = if unhealthy?(state.mode), do: :error, else: :ok
    %{status: status, retained: length(state.entries)}
  end

  def entries(name), do: Agent.get(name, &Enum.reverse(&1.entries))
  def attempts(name), do: Agent.get(name, & &1.attempts)
  def attempts(name, id), do: Agent.get(name, &Map.get(&1.attempts_by_id, id, 0))
  def flush_attempts(name), do: Agent.get(name, & &1.flush_attempts)
  def mode(name, mode), do: Agent.update(name, &%{&1 | mode: mode})

  defp append_mode({:retryable_for, id}, %{id: id}), do: :retryable
  defp append_mode({:permanent_for, id}, %{id: id}), do: :permanent
  defp append_mode({:invalid_for, id}, %{id: id}), do: :invalid

  defp append_mode({mode, _id}, _entry)
       when mode in [:retryable_for, :permanent_for, :invalid_for],
       do: :ok

  defp append_mode({:block_first_flush, _receiver}, _entry), do: :ok
  defp append_mode(:error, _entry), do: :retryable
  defp append_mode(mode, _entry), do: mode

  defp unhealthy?(:error), do: true
  defp unhealthy?(:permanent), do: true
  defp unhealthy?({:sleep, _milliseconds}), do: true
  defp unhealthy?(_mode), do: false
end

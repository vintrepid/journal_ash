defmodule JournalAsh.EmergencyLimiter do
  @moduledoc false

  use GenServer

  @default_key {JournalAsh.Emergency, :limiter}
  @default_interval 5_000
  @default_poll_interval 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec enqueue(atom(), term()) :: :ok
  def enqueue(reason, key \\ @default_key) do
    case :persistent_term.get(key, :unavailable) do
      :unavailable ->
        :ok

      runtime ->
        _inserted = :ets.insert_new(runtime.queue, {:pending, safe_reason(reason)})
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec default_key() :: term()
  def default_key, do: @default_key

  @doc false
  @spec invalidate(term()) :: :ok
  def invalidate(key \\ @default_key) do
    :persistent_term.erase(key)
    :ok
  end

  @impl true
  def init(options) do
    key = Keyword.get(options, :key, @default_key)
    interval = bounded_interval(Keyword.get(options, :interval, @default_interval))

    poll_interval =
      options
      |> Keyword.get(:poll_interval, @default_poll_interval)
      |> bounded_poll_interval(interval)

    queue =
      :ets.new(:journal_ash_emergency_queue, [
        :set,
        :public,
        write_concurrency: true
      ])

    :persistent_term.put(key, %{queue: queue})

    state = %{
      interval: interval,
      key: key,
      last_emitted_at: System.monotonic_time(:millisecond) - interval - 1,
      poll_interval: poll_interval,
      queue: queue,
      sink: Keyword.get(options, :sink, :standard_error),
      timer: nil
    }

    {:ok, schedule_tick(state, poll_interval)}
  end

  @impl true
  def handle_info({:emit_tick, token}, %{timer: %{token: token}} = state) do
    state = %{state | timer: nil}

    case :ets.lookup(state.queue, :pending) do
      [{:pending, reason}] -> maybe_emit(reason, state)
      [] -> {:noreply, schedule_tick(state, state.poll_interval)}
    end
  end

  def handle_info({:emit_tick, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    invalidate(state.key)
  end

  defp maybe_emit(reason, state) do
    now = System.monotonic_time(:millisecond)
    remaining = state.interval - (now - state.last_emitted_at)

    if remaining <= 0 do
      safe_emit(state.sink, reason)
      :ets.delete(state.queue, :pending)

      state = %{state | last_emitted_at: System.monotonic_time(:millisecond)}
      {:noreply, schedule_tick(state, state.poll_interval)}
    else
      {:noreply, schedule_tick(state, remaining)}
    end
  end

  defp schedule_tick(%{timer: nil} = state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:emit_tick, token}, delay)
    %{state | timer: %{ref: timer, token: token}}
  end

  defp bounded_interval(interval) when is_integer(interval) and interval > 0,
    do: min(interval, 60_000)

  defp bounded_interval(_interval), do: @default_interval

  defp bounded_poll_interval(poll_interval, interval)
       when is_integer(poll_interval) and poll_interval > 0,
       do: min(poll_interval, interval)

  defp bounded_poll_interval(_poll_interval, interval), do: min(@default_poll_interval, interval)

  defp safe_reason(reason)
       when reason in [:full, :unavailable, :invalid_logger_event, :slot_busy],
       do: reason

  defp safe_reason(_reason), do: :handler_failure

  defp safe_emit(sink, reason) do
    emit(sink, reason)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit(:standard_error, reason),
    do: :io.put_chars(:standard_error, JournalAsh.Emergency.fixed_message(reason))

  defp emit(pid, reason) when is_pid(pid), do: send(pid, {:journal_ash_emergency, reason})

  defp emit({module, options}, reason) when is_atom(module), do: module.emit(reason, options)

  defp emit(_sink, _reason), do: :ok
end

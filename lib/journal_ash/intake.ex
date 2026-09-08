defmodule JournalAsh.Intake do
  @moduledoc false

  use GenServer

  alias JournalAsh.{Decision, Entry, Envelope, Internal, Telemetry}

  @accepted 1
  @dropped 2
  @sequence 3
  @admission_dropped 4
  @last_admission_drop_at 5
  @flush_sequence 6
  @terminal_dropped 7
  @counter_size 7

  @default_capacity 1_024
  @hard_capacity 4_096
  @default_batch_size 100
  @hard_batch_size 1_000
  @maximum_slot_probes 32
  @default_retry_interval 100
  @default_max_entry_attempts 5
  @hard_max_entry_attempts 100
  @default_sweep_interval 100
  @default_recent_drop_window 60_000
  @hard_recent_drop_window 300_000
  @high_utilization_threshold 0.8
  @high_utilization_percent 80
  @maximum_timestamp_update_attempts 4
  @maximum_flush_timeout 60_000
  @maximum_flush_waiters 64

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec accept(Envelope.t(), Decision.t(), GenServer.name()) :: :ok | {:dropped, atom()}
  def accept(%Envelope{} = envelope, %Decision{} = decision, name \\ __MODULE__) do
    case Decision.validate(decision) do
      {:ok, decision} ->
        case :persistent_term.get(runtime_key(name), :unavailable) do
          :unavailable -> {:dropped, :unavailable}
          runtime -> enqueue(runtime, envelope, decision)
        end

      {:error, :invalid_decision} ->
        reject_invalid_decision(name)
    end
  rescue
    _error -> {:dropped, :unavailable}
  catch
    _kind, _reason -> {:dropped, :unavailable}
  end

  @doc false
  @spec invalidate(GenServer.name()) :: :ok
  def invalidate(name \\ __MODULE__) do
    :persistent_term.erase(runtime_key(name))
    :ok
  end

  @spec health(GenServer.name()) :: map()
  def health(name \\ __MODULE__) do
    if GenServer.whereis(name) do
      GenServer.call(name, :health)
    else
      %{status: :unavailable}
    end
  catch
    :exit, _reason -> %{status: :unavailable}
  end

  @spec flush(GenServer.name(), pos_integer()) :: :ok | {:error, term()}
  def flush(name \\ __MODULE__, timeout \\ 5_000)

  def flush(name, timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @maximum_flush_timeout do
    deadline = System.monotonic_time(:millisecond) + timeout

    case reserve_flush(name) do
      {:ok, reservation} ->
        try do
          GenServer.call(name, {:flush, deadline, reservation}, timeout + 100)
        catch
          :exit, {:timeout, _details} ->
            {:error, :timeout}

          :exit, _reason ->
            release_flush(reservation)
            {:error, :unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def flush(_name, _timeout), do: {:error, :invalid_timeout}

  @impl true
  def init(options) do
    name = Keyword.get(options, :name, __MODULE__)
    capacity = bounded(Keyword.get(options, :capacity), @default_capacity, @hard_capacity)
    batch_size = bounded(Keyword.get(options, :batch_size), @default_batch_size, @hard_batch_size)

    retry_interval =
      bounded(Keyword.get(options, :retry_interval), @default_retry_interval, 60_000)

    max_entry_attempts =
      bounded(
        Keyword.get(options, :max_entry_attempts),
        @default_max_entry_attempts,
        @hard_max_entry_attempts
      )

    sweep_interval =
      bounded(Keyword.get(options, :sweep_interval), @default_sweep_interval, 60_000)

    recent_drop_window =
      bounded(
        Keyword.get(options, :recent_drop_window),
        @default_recent_drop_window,
        @hard_recent_drop_window
      )

    queue =
      :ets.new(:journal_ash_intake_queue, [
        :ordered_set,
        :public,
        write_concurrency: true
      ])

    flush_reservations =
      :ets.new(:journal_ash_flush_reservations, [
        :set,
        :public,
        write_concurrency: true
      ])

    counters = :atomics.new(@counter_size, signed: true)
    :atomics.put(counters, @last_admission_drop_at, System.monotonic_time(:millisecond))

    runtime = %{
      queue: queue,
      counters: counters,
      capacity: capacity,
      flush_reservations: flush_reservations
    }

    :persistent_term.put(runtime_key(name), runtime)

    state =
      %{
        name: name,
        queue: queue,
        flush_reservations: flush_reservations,
        counters: counters,
        capacity: capacity,
        batch_size: batch_size,
        max_entry_attempts: max_entry_attempts,
        retry_interval: retry_interval,
        sweep_interval: sweep_interval,
        recent_drop_window: recent_drop_window,
        store: Keyword.fetch!(options, :store),
        last_error: nil,
        retryable_failures: 0,
        permanent_failures: 0,
        retry_exhausted: 0,
        retrying_entries: 0,
        terminal_dropped: 0,
        last_terminal_drop_at: nil,
        flush_waiters: [],
        drain_cursor: 0,
        timer: nil
      }

    {:ok, schedule_tick(state, sweep_interval)}
  end

  @impl true
  def handle_info({:drain_tick, token}, %{timer: %{token: token}} = state) do
    state = state |> Map.put(:timer, nil) |> expire_flush_waiters() |> sweep_flush_reservations()
    {result, state} = drain_batch(state, state.batch_size)
    {:noreply, schedule_next(result, state)}
  end

  def handle_info({:drain_tick, _stale_token}, state), do: {:noreply, state}

  @impl true
  def handle_call(:health, _from, state) do
    state = sweep_flush_reservations(state)
    pending = pending(state)
    store_health = safe_store_health(state.store)
    utilization = pending / state.capacity
    high_utilization = pending * 100 >= state.capacity * @high_utilization_percent
    admission_dropped = counter(state, @admission_dropped)
    last_admission_drop_age = last_admission_drop_age(state, admission_dropped)

    recent_admission_drop =
      is_integer(last_admission_drop_age) and
        last_admission_drop_age <= state.recent_drop_window

    last_terminal_drop_age = last_terminal_drop_age(state)

    recent_terminal_drop =
      is_integer(last_terminal_drop_age) and
        last_terminal_drop_age <= state.recent_drop_window

    status =
      cond do
        pending >= state.capacity -> :saturated
        recent_admission_drop -> :degraded
        recent_terminal_drop -> :degraded
        high_utilization -> :degraded
        state.retrying_entries > 0 -> :degraded
        state.last_error -> :degraded
        not store_ready?(store_health) -> :degraded
        true -> :ready
      end

    health = %{
      status: status,
      pending: pending,
      capacity: state.capacity,
      accepted: counter(state, @accepted),
      dropped: counter(state, @dropped),
      admission_dropped: admission_dropped,
      recent_admission_drop: recent_admission_drop,
      last_admission_drop_age_ms: last_admission_drop_age,
      recent_drop_window_ms: state.recent_drop_window,
      queue_utilization: utilization,
      high_queue_utilization: high_utilization,
      high_queue_utilization_threshold: @high_utilization_threshold,
      max_entry_attempts: state.max_entry_attempts,
      retryable_failures: state.retryable_failures,
      permanent_failures: state.permanent_failures,
      retry_exhausted: state.retry_exhausted,
      retrying_entries: state.retrying_entries,
      terminal_dropped: state.terminal_dropped,
      recent_terminal_drop: recent_terminal_drop,
      last_terminal_drop_age_ms: last_terminal_drop_age,
      flush_waiters: length(state.flush_waiters),
      flush_reservations: flush_reservations(state),
      last_error: state.last_error,
      store: store_health
    }

    {:reply, health, state}
  end

  def handle_call({:flush, deadline, reservation}, from, state) do
    reservation = %{reservation | owner: elem(from, 0)}

    cond do
      not flush_reserved?(state.flush_reservations, reservation) ->
        {:reply, {:error, :unavailable}, state}

      deadline <= System.monotonic_time(:millisecond) ->
        release_flush(state.flush_reservations, reservation)
        {:reply, {:error, :timeout}, state}

      length(state.flush_waiters) >= @maximum_flush_waiters ->
        release_flush(state.flush_reservations, reservation)
        {:reply, {:error, :too_many_waiters}, state}

      true ->
        waiter = %{
          from: from,
          deadline: deadline,
          reservation: reservation,
          terminal_dropped: reservation.terminal_dropped
        }

        state = %{state | flush_waiters: [waiter | state.flush_waiters]}
        {:noreply, reschedule_tick(state, 0)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    invalidate(state.name)
  end

  defp enqueue(runtime, envelope, decision) do
    sequence = :atomics.add_get(runtime.counters, @sequence, 1)
    starting_slot = rem(sequence - 1, runtime.capacity)
    maximum_probes = min(runtime.capacity, @maximum_slot_probes)

    case claim_slot(runtime, starting_slot, maximum_probes, sequence, envelope, decision) do
      :ok ->
        _accepted = :atomics.add_get(runtime.counters, @accepted, 1)
        :ok

      :busy ->
        reason =
          if :ets.info(runtime.queue, :size) >= runtime.capacity, do: :full, else: :slot_busy

        record_admission_drop(runtime)
        {:dropped, reason}
    end
  rescue
    _error ->
      record_admission_drop(runtime)
      {:dropped, :unavailable}
  catch
    _kind, _reason ->
      record_admission_drop(runtime)
      {:dropped, :unavailable}
  end

  defp record_admission_drop(runtime) do
    record_latest_admission_drop(
      runtime.counters,
      System.monotonic_time(:millisecond),
      @maximum_timestamp_update_attempts
    )

    _admission_dropped = :atomics.add_get(runtime.counters, @admission_dropped, 1)
    _dropped = :atomics.add_get(runtime.counters, @dropped, 1)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_latest_admission_drop(_counters, _dropped_at, 0), do: :ok

  defp record_latest_admission_drop(counters, dropped_at, attempts) do
    current = :atomics.get(counters, @last_admission_drop_at)

    if dropped_at > current do
      case :atomics.compare_exchange(
             counters,
             @last_admission_drop_at,
             current,
             dropped_at
           ) do
        :ok -> :ok
        observed when observed >= dropped_at -> :ok
        _older -> record_latest_admission_drop(counters, dropped_at, attempts - 1)
      end
    else
      :ok
    end
  end

  defp reject_invalid_decision(name) do
    case :persistent_term.get(runtime_key(name), :unavailable) do
      %{counters: counters} ->
        _dropped = :atomics.add_get(counters, @dropped, 1)
        {:dropped, :invalid_decision}

      :unavailable ->
        {:dropped, :invalid_decision}
    end
  rescue
    _error -> {:dropped, :invalid_decision}
  catch
    _kind, _reason -> {:dropped, :invalid_decision}
  end

  defp claim_slot(_runtime, _slot, 0, _sequence, _envelope, _decision), do: :busy

  defp claim_slot(runtime, slot, remaining, sequence, envelope, decision) do
    if :ets.insert_new(runtime.queue, {slot, sequence, envelope, decision, 0, nil}) do
      :ok
    else
      next_slot = rem(slot + 1, runtime.capacity)
      claim_slot(runtime, next_slot, remaining - 1, sequence, envelope, decision)
    end
  end

  defp drain_batch(state, maximum) do
    if pending(state) == 0 do
      {:empty, state}
    else
      drain_slots(state, maximum, state.capacity, System.monotonic_time(:millisecond))
    end
  end

  defp drain_slots(state, 0, _remaining_slots, _now), do: {:ready, state}

  defp drain_slots(state, _remaining_entries, 0, _now) do
    if pending(state) == 0, do: {:empty, state}, else: {:retry, state}
  end

  defp drain_slots(state, remaining_entries, remaining_slots, now) do
    slot = state.drain_cursor
    advanced = %{state | drain_cursor: rem(slot + 1, state.capacity)}

    case :ets.lookup(state.queue, slot) do
      [] ->
        drain_slots(advanced, remaining_entries, remaining_slots - 1, now)

      [{^slot, _sequence, _envelope, _decision, _attempts, retry_at}]
      when is_integer(retry_at) and retry_at > now ->
        drain_slots(advanced, remaining_entries, remaining_slots - 1, now)

      [{^slot, _sequence, envelope, decision, attempts, _retry_at}]
      when is_integer(attempts) and attempts >= 0 ->
        process_entry(
          advanced,
          slot,
          envelope,
          decision,
          attempts,
          remaining_entries,
          remaining_slots,
          now
        )

      [_malformed] ->
        dequeue(state, slot)

        state =
          advanced
          |> record_terminal_drop()
          |> clear_inactive_error()

        drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)
    end
  end

  defp process_entry(
         state,
         slot,
         envelope,
         decision,
         attempts,
         remaining_entries,
         remaining_slots,
         now
       ) do
    case retain(envelope, decision, state.store) do
      :ok ->
        dequeue(state, slot)

        state =
          state
          |> leave_retry(attempts)
          |> clear_inactive_error()

        drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)

      {:drop, _reason} ->
        dequeue(state, slot)

        state =
          state
          |> leave_retry(attempts)
          |> record_terminal_drop()
          |> clear_inactive_error()

        drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)

      {:permanent, _reason} ->
        dequeue(state, slot)

        state =
          state
          |> leave_retry(attempts)
          |> record_terminal_drop()
          |> Map.update!(:permanent_failures, &(&1 + 1))
          |> clear_inactive_error()

        drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)

      {:retry, _reason} ->
        retry_entry(
          state,
          slot,
          envelope,
          decision,
          attempts,
          remaining_entries,
          remaining_slots,
          now
        )
    end
  end

  defp retry_entry(
         state,
         slot,
         envelope,
         decision,
         attempts,
         remaining_entries,
         remaining_slots,
         now
       ) do
    attempts = attempts + 1
    state = %{state | retryable_failures: state.retryable_failures + 1}

    if attempts >= state.max_entry_attempts do
      dequeue(state, slot)

      state =
        state
        |> leave_retry(attempts - 1)
        |> record_terminal_drop()
        |> Map.update!(:retry_exhausted, &(&1 + 1))
        |> clear_inactive_error()

      drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)
    else
      retry_at = now + state.retry_interval

      sequence =
        case :ets.lookup(state.queue, slot) do
          [{^slot, sequence, ^envelope, ^decision, _old_attempts, _old_retry_at}] ->
            sequence
        end

      true = :ets.insert(state.queue, {slot, sequence, envelope, decision, attempts, retry_at})

      state = %{
        state
        | retrying_entries: state.retrying_entries + if(attempts == 1, do: 1, else: 0),
          last_error: :store_retryable
      }

      drain_slots(state, remaining_entries - 1, remaining_slots - 1, now)
    end
  end

  defp record_terminal_drop(state) do
    _dropped = :atomics.add_get(state.counters, @dropped, 1)
    terminal_dropped = :atomics.add_get(state.counters, @terminal_dropped, 1)

    %{
      state
      | terminal_dropped: terminal_dropped,
        last_terminal_drop_at: System.monotonic_time(:millisecond)
    }
  end

  defp leave_retry(state, attempts) when attempts > 0 do
    %{state | retrying_entries: max(state.retrying_entries - 1, 0)}
  end

  defp leave_retry(state, _attempts), do: state

  defp clear_inactive_error(%{retrying_entries: 0} = state), do: %{state | last_error: nil}
  defp clear_inactive_error(state), do: state

  defp retain(envelope, decision, store) do
    Internal.run(fn -> retain_and_project(envelope, decision, store) end)
  rescue
    _error -> {:retry, :store_callback_failure}
  catch
    _kind, _reason -> {:retry, :store_callback_failure}
  end

  defp retain_and_project(envelope, decision, store) do
    result =
      if Decision.retain?(decision) do
        case Entry.from_observation(envelope, decision) do
          {:ok, entry} ->
            case safe_store_append(store, entry) do
              :ok -> :ok
              {:error, {:retryable, _reason}} -> {:retry, :store_retryable}
              {:error, {:permanent, _reason}} -> {:permanent, :store_permanent}
              _undocumented -> {:permanent, :invalid_store_result}
            end

          {:error, _reason} ->
            {:drop, :invalid_entry}
        end
      else
        :ok
      end

    if result == :ok, do: Telemetry.emit(envelope, decision)
    result
  end

  defp dequeue(state, slot) do
    :ets.delete(state.queue, slot)
    :ok
  end

  defp schedule_next(:retry, state) do
    schedule_tick(state, bounded_by_flush_deadline(state, state.retry_interval))
  end

  defp schedule_next(:empty, state), do: finish_cycle(state)

  defp schedule_next(:ready, state) do
    if pending(state) > 0 do
      schedule_tick(state, 0)
    else
      finish_cycle(state)
    end
  end

  defp finish_cycle(state) do
    state = expire_flush_waiters(state)

    case state.flush_waiters do
      [] -> schedule_tick(state, state.sweep_interval)
      _waiters -> finish_flush(state)
    end
  end

  defp finish_flush(state) do
    case safe_store_flush(state.store) do
      :ok ->
        state = expire_flush_waiters(state)

        cond do
          state.flush_waiters == [] ->
            schedule_tick(state, state.sweep_interval)

          pending(state) > 0 ->
            # Admission writes directly to ETS and can race a store callback.
            # Rechecking after flush gives successful callers a real empty-queue
            # linearization point instead of a stale pre-callback observation.
            schedule_tick(state, 0)

          true ->
            state
            |> reply_to_flush_waiters(:ok)
            |> schedule_tick(state.sweep_interval)
        end

      {:error, _reason} ->
        state
        |> expire_flush_waiters()
        |> reply_to_flush_waiters({:error, :store_failure})
        |> schedule_tick(state.sweep_interval)
    end
  end

  defp expire_flush_waiters(%{flush_waiters: []} = state), do: state

  defp expire_flush_waiters(state) do
    now = System.monotonic_time(:millisecond)

    {active, finished} =
      Enum.split_with(state.flush_waiters, fn waiter ->
        waiter.deadline > now and Process.alive?(waiter.reservation.owner)
      end)

    Enum.each(finished, fn waiter ->
      release_flush(state.flush_reservations, waiter.reservation)

      if Process.alive?(waiter.reservation.owner) do
        GenServer.reply(waiter.from, {:error, :timeout})
      end
    end)

    %{state | flush_waiters: active}
  end

  defp reply_to_flush_waiters(state, result) do
    now = System.monotonic_time(:millisecond)

    Enum.each(state.flush_waiters, fn waiter ->
      reply =
        cond do
          waiter.deadline <= now -> {:error, :timeout}
          state.terminal_dropped > waiter.terminal_dropped -> {:error, :entries_dropped}
          true -> result
        end

      release_flush(state.flush_reservations, waiter.reservation)
      GenServer.reply(waiter.from, reply)
    end)

    %{state | flush_waiters: []}
  end

  defp bounded_by_flush_deadline(%{flush_waiters: []}, delay), do: delay

  defp bounded_by_flush_deadline(state, delay) do
    now = System.monotonic_time(:millisecond)
    deadline = state.flush_waiters |> Enum.map(& &1.deadline) |> Enum.min()
    min(delay, max(deadline - now, 0))
  end

  defp safe_store_append({module, options}, entry) do
    module.append(entry, options)
  rescue
    _error -> {:error, {:retryable, :store_callback_failure}}
  catch
    _kind, _reason -> {:error, {:retryable, :store_callback_failure}}
  end

  defp safe_store_flush({module, options}) do
    case Internal.run(fn -> module.flush(options) end) do
      :ok -> :ok
      {:error, _reason} -> {:error, :store_failure}
      _undocumented -> {:error, :store_failure}
    end
  rescue
    _error -> {:error, :store_failure}
  catch
    _kind, _reason -> {:error, :store_failure}
  end

  defp safe_store_health({module, options}) do
    Internal.run(fn -> module.health(options) end)
  rescue
    _error -> %{status: :unavailable}
  catch
    _kind, _reason -> %{status: :unavailable}
  end

  defp store_ready?(%{status: status}) when status in [:ok, :ready, :healthy], do: true
  defp store_ready?(_health), do: false

  defp counter(state, index), do: :atomics.get(state.counters, index)

  defp last_admission_drop_age(_state, 0), do: nil

  defp last_admission_drop_age(state, _admission_dropped) do
    last_dropped_at = counter(state, @last_admission_drop_at)
    max(System.monotonic_time(:millisecond) - last_dropped_at, 0)
  end

  defp last_terminal_drop_age(%{last_terminal_drop_at: nil}), do: nil

  defp last_terminal_drop_age(state) do
    max(System.monotonic_time(:millisecond) - state.last_terminal_drop_at, 0)
  end

  defp pending(state), do: :ets.info(state.queue, :size)

  defp bounded(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded(_value, default, _maximum), do: default

  defp schedule_tick(%{timer: nil} = state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:drain_tick, token}, delay)
    %{state | timer: %{ref: timer, token: token}}
  end

  defp schedule_tick(state, _delay), do: state

  defp reschedule_tick(state, delay) do
    state
    |> cancel_tick()
    |> schedule_tick(delay)
  end

  defp cancel_tick(%{timer: nil} = state), do: state

  defp cancel_tick(state) do
    _cancelled = Process.cancel_timer(state.timer.ref, async: true, info: false)
    %{state | timer: nil}
  end

  defp reserve_flush(name) do
    case :persistent_term.get(runtime_key(name), :unavailable) do
      :unavailable ->
        {:error, :unavailable}

      runtime ->
        terminal_dropped = :atomics.get(runtime.counters, @terminal_dropped)
        sequence = :atomics.add_get(runtime.counters, @flush_sequence, 1)
        starting_slot = rem(sequence - 1, @maximum_flush_waiters)
        token = make_ref()

        case claim_flush_reservation(
               runtime.flush_reservations,
               starting_slot,
               @maximum_flush_waiters,
               token
             ) do
          {:ok, slot} ->
            {:ok,
             %{
               table: runtime.flush_reservations,
               slot: slot,
               token: token,
               owner: self(),
               terminal_dropped: terminal_dropped
             }}

          :full ->
            {:error, :too_many_waiters}
        end
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp claim_flush_reservation(_table, _slot, 0, _token), do: :full

  defp claim_flush_reservation(table, slot, remaining, token) do
    if :ets.insert_new(table, {slot, self(), token}) do
      {:ok, slot}
    else
      claim_flush_reservation(
        table,
        rem(slot + 1, @maximum_flush_waiters),
        remaining - 1,
        token
      )
    end
  end

  defp flush_reserved?(table, %{slot: slot, token: token, owner: owner}) do
    :ets.lookup(table, slot) == [{slot, owner, token}]
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp release_flush(%{table: table} = reservation) do
    release_flush(table, reservation)
  end

  defp release_flush(table, %{slot: slot, token: token, owner: owner}) do
    :ets.delete_object(table, {slot, owner, token})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp sweep_flush_reservations(state) do
    :ets.foldl(
      fn {slot, owner, token}, :ok ->
        if Process.alive?(owner) do
          :ok
        else
          :ets.match_delete(state.flush_reservations, {slot, owner, token})
          :ok
        end
      end,
      :ok,
      state.flush_reservations
    )

    state
  end

  defp flush_reservations(state), do: :ets.info(state.flush_reservations, :size)

  defp runtime_key(name), do: {__MODULE__, name}
end

defmodule JournalAsh.IntakeTest do
  use ExUnit.Case, async: true

  alias JournalAsh.{Decision, Envelope, Intake, TestStore}

  test "capacity remains hard-bounded when the store is unavailable" do
    {intake, store_name} = start_pipeline(capacity: 8, mode: :error)
    decision = retained()

    results =
      1..100
      |> Task.async_stream(
        fn _index -> Intake.accept(observation(), decision, intake) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 8
    assert Enum.count(results, &(&1 == {:dropped, :full})) == 92

    health = Intake.health(intake)
    assert health.pending == 8
    assert health.capacity == 8
    assert health.dropped == 92
    assert health.admission_dropped == 92
    assert health.recent_admission_drop
    assert health.status == :saturated
    assert TestStore.entries(store_name) == []
  end

  test "health is degraded when the store is unhealthy even with an empty queue" do
    {intake, _store_name} = start_pipeline(capacity: 2, mode: :error)

    assert %{status: :degraded, pending: 0, store: %{status: :error}} = Intake.health(intake)
  end

  test "health remains degraded for a bounded window after admission loss" do
    {intake, store_name} =
      start_pipeline(
        capacity: 1,
        mode: :error,
        recent_drop_window: 5_000,
        sweep_interval: 60_000
      )

    assert :ok = Intake.accept(observation(), retained(), intake)
    assert {:dropped, :full} = Intake.accept(observation(), retained(), intake)

    TestStore.mode(store_name, :ok)
    assert :ok = Intake.flush(intake, 1_000)

    assert %{
             status: :degraded,
             pending: 0,
             admission_dropped: 1,
             recent_admission_drop: true,
             last_admission_drop_age_ms: age,
             recent_drop_window_ms: 5_000
           } = Intake.health(intake)

    assert age >= 0

    # Move the internal monotonic marker past the configured window without a
    # wall-clock sleep, keeping this health-state test deterministic.
    runtime = :persistent_term.get({Intake, intake})
    expired_at = System.monotonic_time(:millisecond) - 5_001
    :ok = :atomics.put(runtime.counters, 5, expired_at)

    assert %{status: :ready, recent_admission_drop: false} = Intake.health(intake)
  end

  test "health degrades before a high-utilization queue becomes saturated" do
    {intake, _store_name} =
      start_pipeline(capacity: 10, mode: :ok, sweep_interval: 60_000)

    Enum.each(1..8, fn _index ->
      assert :ok = Intake.accept(observation(), retained(), intake)
    end)

    assert %{
             status: :degraded,
             pending: 8,
             queue_utilization: 0.8,
             high_queue_utilization: true,
             high_queue_utilization_threshold: 0.8,
             recent_admission_drop: false
           } = Intake.health(intake)
  end

  test "host configuration cannot raise the queue capacity above its hard ceiling" do
    {intake, _store_name} =
      start_pipeline(
        capacity: 1_000_000,
        max_entry_attempts: 1_000_000,
        recent_drop_window: 1_000_000,
        mode: :ok
      )

    assert %{
             capacity: 4_096,
             max_entry_attempts: 100,
             recent_drop_window_ms: 300_000
           } = Intake.health(intake)
  end

  test "admission probes bounded alternate slots after a sequence gap" do
    {intake, _store_name} =
      start_pipeline(capacity: 2, mode: :error, sweep_interval: 60_000)

    runtime = :persistent_term.get({Intake, intake})
    assert :ok = Intake.accept(observation(), retained(), intake)

    # Model a producer that consumed sequence 2 but exited before insertion.
    :atomics.put(runtime.counters, 3, 2)

    assert :ok = Intake.accept(observation(), retained(), intake)
    assert :ets.info(runtime.queue, :size) == 2
  end

  test "accepting an event does not wait for a slow store" do
    {intake, _store_name} = start_pipeline(capacity: 2, mode: {:sleep, 250})
    started_at = System.monotonic_time(:millisecond)

    assert :ok = Intake.accept(observation(), retained(), intake)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 100
  end

  test "retries retained observations and flushes after the store recovers" do
    {intake, store_name} =
      start_pipeline(
        capacity: 2,
        mode: :error,
        max_entry_attempts: 100,
        retry_interval: 10,
        sweep_interval: 10
      )

    envelope = observation()

    assert :ok = Intake.accept(envelope, retained(), intake)
    assert eventually(fn -> TestStore.attempts(store_name) > 0 end)

    TestStore.mode(store_name, :ok)

    assert :ok = Intake.flush(intake, 1_000)
    assert [%{id: id}] = TestStore.entries(store_name)
    assert id == envelope.id
    assert Intake.health(intake).pending == 0
  end

  test "transient policy still enters intake but is not retained" do
    {intake, store_name} = start_pipeline(capacity: 2, mode: :ok)
    telemetry_handler = {__MODULE__, self(), make_ref()}
    envelope = observation()

    :ok =
      :telemetry.attach(
        telemetry_handler,
        JournalAsh.Telemetry.event(),
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    decision = %Decision{retention: :transient, projections: [:telemetry]}

    assert :ok = Intake.accept(envelope, decision, intake)
    assert :ok = Intake.flush(intake, 1_000)
    assert TestStore.entries(store_name) == []
    assert Intake.health(intake).accepted == 1

    assert_receive {:telemetry, [:journal_ash, :observation], %{count: 1}, metadata}
    assert metadata.event == "test.intake"
    assert metadata.id == envelope.id
    refute Map.has_key?(metadata, :message)
  end

  test "invalid decisions are rejected before queue admission" do
    {intake, store_name} = start_pipeline(capacity: 2, mode: :ok)
    invalid = %Decision{retention: :retain, projections: :not_a_projection_list}

    assert {:dropped, :invalid_decision} = Intake.accept(observation(), invalid, intake)
    assert :ok = Intake.flush(intake, 1_000)
    assert TestStore.attempts(store_name) == 0

    assert %{
             accepted: 0,
             dropped: 1,
             admission_dropped: 0,
             recent_admission_drop: false,
             pending: 0,
             last_error: nil
           } = Intake.health(intake)
  end

  test "telemetry exposes a stable identity for duplicate-capable delivery" do
    {intake, _store_name} = start_pipeline(capacity: 2, mode: :ok)
    telemetry_handler = {__MODULE__, self(), make_ref()}
    envelope = observation()

    :ok =
      :telemetry.attach(
        telemetry_handler,
        JournalAsh.Telemetry.event(),
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    decision = %Decision{retention: :transient, projections: [:telemetry]}

    assert :ok = Intake.accept(envelope, decision, intake)
    assert :ok = Intake.accept(envelope, decision, intake)
    assert :ok = Intake.flush(intake, 1_000)

    assert_receive {:telemetry, [:journal_ash, :observation], %{count: 1}, first}
    assert_receive {:telemetry, [:journal_ash, :observation], %{count: 1}, second}
    assert first.id == envelope.id
    assert second.id == envelope.id
  end

  test "the server-owned tick recovers a slot when its producer exits without a wake-up" do
    {intake, store_name} = start_pipeline(capacity: 2, mode: :ok, sweep_interval: 10)
    envelope = observation()
    parent = self()

    {_producer, monitor} =
      spawn_monitor(fn ->
        :ok = Intake.accept(envelope, retained(), intake)
        send(parent, :orphan_inserted)
        exit(:simulated_producer_death)
      end)

    assert_receive :orphan_inserted
    assert_receive {:DOWN, ^monitor, :process, _pid, :simulated_producer_death}
    assert eventually(fn -> Enum.map(TestStore.entries(store_name), & &1.id) == [envelope.id] end)
    assert Intake.health(intake).pending == 0
  end

  test "flush actively recovers an admitted slot without waiting for the idle tick" do
    {intake, store_name} = start_pipeline(capacity: 2, mode: :ok, sweep_interval: 60_000)
    envelope = observation()

    assert :ok = Intake.accept(envelope, retained(), intake)
    assert :ok = Intake.flush(intake, 1_000)
    assert Enum.map(TestStore.entries(store_name), & &1.id) == [envelope.id]
  end

  test "flush drains an admission that races the store flush callback" do
    first = observation()
    second = observation()

    {intake, store_name} =
      start_pipeline(
        capacity: 4,
        mode: {:block_first_flush, self()},
        sweep_interval: 60_000
      )

    assert :ok = Intake.accept(first, retained(), intake)
    flusher = Task.async(fn -> Intake.flush(intake, 2_000) end)

    assert_receive {:journal_ash_test_flush_started, intake_pid}, 1_000
    assert :ok = Intake.accept(second, retained(), intake)
    send(intake_pid, :release_journal_ash_test_flush)

    assert :ok = Task.await(flusher, 2_500)
    assert Enum.map(TestStore.entries(store_name), & &1.id) == [first.id, second.id]
    assert TestStore.flush_attempts(store_name) == 2
  end

  test "retryable failures do not block later entries and exhaust at a fixed limit" do
    rejected = observation()
    accepted = observation()

    {intake, store_name} =
      start_pipeline(
        capacity: 4,
        max_entry_attempts: 3,
        mode: {:retryable_for, rejected.id},
        retry_interval: 5,
        sweep_interval: 60_000
      )

    assert :ok = Intake.accept(rejected, retained(), intake)
    assert :ok = Intake.accept(accepted, retained(), intake)
    assert {:error, :entries_dropped} = Intake.flush(intake, 1_000)

    assert Enum.map(TestStore.entries(store_name), & &1.id) == [accepted.id]
    assert TestStore.attempts(store_name, rejected.id) == 3
    assert TestStore.attempts(store_name, accepted.id) == 1

    assert %{
             status: :degraded,
             pending: 0,
             dropped: 1,
             retryable_failures: 3,
             retry_exhausted: 1,
             retrying_entries: 0,
             permanent_failures: 0,
             terminal_dropped: 1
           } = Intake.health(intake)

    assert :ok = Intake.flush(intake, 1_000)
  end

  test "permanent and undocumented store results are terminal without pinning the queue" do
    Enum.each([:permanent_for, :invalid_for], fn mode ->
      rejected = observation()
      accepted = observation()

      {intake, store_name} =
        start_pipeline(
          capacity: 4,
          max_entry_attempts: 10,
          mode: {mode, rejected.id},
          sweep_interval: 60_000
        )

      assert :ok = Intake.accept(rejected, retained(), intake)
      assert :ok = Intake.accept(accepted, retained(), intake)
      assert {:error, :entries_dropped} = Intake.flush(intake, 1_000)

      assert Enum.map(TestStore.entries(store_name), & &1.id) == [accepted.id]
      assert TestStore.attempts(store_name, rejected.id) == 1

      assert %{
               status: :degraded,
               pending: 0,
               dropped: 1,
               retryable_failures: 0,
               retry_exhausted: 0,
               retrying_entries: 0,
               permanent_failures: 1,
               terminal_dropped: 1
             } = Intake.health(intake)
    end)
  end

  test "a long store outage retains one bounded retry timer" do
    {intake, store_name} =
      start_pipeline(
        capacity: 2,
        max_entry_attempts: 100,
        mode: :error,
        retry_interval: 5,
        sweep_interval: 1
      )

    assert :ok = Intake.accept(observation(), retained(), intake)
    assert eventually(fn -> TestStore.attempts(store_name) > 2 end)
    Process.sleep(50)

    intake_pid = GenServer.whereis(intake)
    {:message_queue_len, message_count} = Process.info(intake_pid, :message_queue_len)

    assert message_count <= 1
    assert TestStore.attempts(store_name) < 30
    assert Intake.health(intake).pending == 1
  end

  test "invalid large flush timeouts do not crash intake or lose queued entries" do
    {intake, store_name} =
      start_pipeline(capacity: 2, mode: :error, sweep_interval: 60_000)

    envelope = observation()
    assert :ok = Intake.accept(envelope, retained(), intake)
    intake_pid = GenServer.whereis(intake)

    assert {:error, :invalid_timeout} = Intake.flush(intake, 9_223_372_036_854_775_807)
    assert Process.alive?(intake_pid)
    assert Intake.health(intake).pending == 1

    TestStore.mode(store_name, :ok)
    assert :ok = Intake.flush(intake, 1_000)
    assert Enum.map(TestStore.entries(store_name), & &1.id) == [envelope.id]
  end

  test "flush reservations bound callers and mailbox growth while a store callback blocks" do
    {intake, _store_name} =
      start_pipeline(
        capacity: 2,
        mode: {:block_first_flush, self()},
        sweep_interval: 60_000
      )

    callers = Enum.map(1..80, fn _index -> Task.async(fn -> Intake.flush(intake, 2_000) end) end)

    assert_receive {:journal_ash_test_flush_started, intake_pid}, 1_000
    runtime = :persistent_term.get({Intake, intake})

    assert eventually(fn -> :ets.info(runtime.flush_reservations, :size) == 64 end)
    assert eventually(fn -> Enum.count(callers, &(not Process.alive?(&1.pid))) == 16 end)

    {:message_queue_len, message_count} = Process.info(intake_pid, :message_queue_len)
    assert message_count <= 64

    send(intake_pid, :release_journal_ash_test_flush)
    results = Enum.map(callers, &Task.await(&1, 2_500))

    assert Enum.count(results, &(&1 == :ok)) == 64
    assert Enum.count(results, &(&1 == {:error, :too_many_waiters})) == 16
    assert Intake.health(intake).flush_reservations == 0
  end

  test "caller timeouts cannot reopen admission while their flush messages remain queued" do
    {intake, _store_name} =
      start_pipeline(mode: {:block_first_flush, self()}, sweep_interval: 60_000)

    parent = self()

    start_caller = fn ->
      Task.async(fn ->
        result = Intake.flush(intake, 250)
        send(parent, {:flush_timed_out, self(), result})

        receive do
          :finish -> result
        end
      end)
    end

    first = start_caller.()
    assert_receive {:journal_ash_test_flush_started, intake_pid}, 1_000
    callers = [first | Enum.map(1..63, fn _index -> start_caller.() end)]

    Enum.each(callers, fn %{pid: pid} ->
      assert_receive {:flush_timed_out, ^pid, {:error, :timeout}}, 1_000
    end)

    Enum.each(1..100, fn _index ->
      assert {:error, :too_many_waiters} = Intake.flush(intake, 1)
    end)

    {:message_queue_len, message_count} = Process.info(intake_pid, :message_queue_len)
    assert message_count <= 64

    send(intake_pid, :release_journal_ash_test_flush)
    assert Intake.health(intake).flush_reservations == 0

    Enum.each(callers, fn caller ->
      send(caller.pid, :finish)
      assert {:error, :timeout} = Task.await(caller)
    end)

    assert :ok = Intake.flush(intake, 1_000)
  end

  defp start_pipeline(options) do
    unique = System.unique_integer([:positive, :monotonic])
    store_name = {:global, {__MODULE__, :store, unique}}
    intake_name = {:global, {__MODULE__, :intake, unique}}
    mode = Keyword.get(options, :mode, :ok)

    start_supervised!({TestStore, name: store_name, mode: mode})

    start_supervised!(
      {Intake,
       name: intake_name,
       capacity: Keyword.get(options, :capacity, 8),
       batch_size: 2,
       retry_interval: Keyword.get(options, :retry_interval, 1_000),
       max_entry_attempts: Keyword.get(options, :max_entry_attempts, 5),
       sweep_interval: Keyword.get(options, :sweep_interval, 1_000),
       recent_drop_window: Keyword.get(options, :recent_drop_window, 60_000),
       store: {TestStore, [name: store_name]}},
      id: {Intake, intake_name}
    )

    {intake_name, store_name}
  end

  defp observation do
    %Envelope{
      id: Ash.UUIDv7.generate(),
      kind: :observation,
      source: :logger,
      event: "test.intake",
      level: :info,
      message: "accepted",
      metadata: %{},
      observed_at: DateTime.utc_now()
    }
  end

  defp retained,
    do: %Decision{retention: :retain, projections: [:standard_log], reason: :test}

  defp eventually(function, attempts \\ 50)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, receiver) do
    send(receiver, {:telemetry, event, measurements, metadata})
  end
end

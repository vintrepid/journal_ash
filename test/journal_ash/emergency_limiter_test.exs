defmodule JournalAsh.EmergencyLimiterTest do
  use ExUnit.Case, async: true

  alias JournalAsh.EmergencyLimiter

  test "concurrent callers reserve at most one emergency emission per interval" do
    unique = System.unique_integer([:positive, :monotonic])
    key = {__MODULE__, :limiter, unique}
    name = {:global, {__MODULE__, :server, unique}}

    start_supervised!(
      {EmergencyLimiter, name: name, key: key, interval: 60_000, poll_interval: 1, sink: self()}
    )

    results =
      1..100
      |> Task.async_stream(fn _index -> EmergencyLimiter.enqueue(:full, key) end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :ok))
    assert_receive {:journal_ash_emergency, :full}, 500
    refute_receive {:journal_ash_emergency, :full}, 20
  end

  test "a producer can exit immediately after admission without losing the warning" do
    unique = System.unique_integer([:positive, :monotonic])
    key = {__MODULE__, :recovery_limiter, unique}
    name = {:global, {__MODULE__, :recovery_server, unique}}

    start_supervised!(
      {EmergencyLimiter, name: name, key: key, interval: 5, poll_interval: 1, sink: self()}
    )

    parent = self()

    {_producer, monitor} =
      spawn_monitor(fn ->
        EmergencyLimiter.enqueue(:unavailable, key)
        send(parent, :warning_admitted)
        exit(:simulated_producer_death)
      end)

    assert_receive :warning_admitted
    assert_receive {:DOWN, ^monitor, :process, _pid, :simulated_producer_death}
    assert_receive {:journal_ash_emergency, :unavailable}, 500
  end

  test "a blocked emergency sink cannot grow intake or its mailbox" do
    unique = System.unique_integer([:positive, :monotonic])
    key = {__MODULE__, :blocked_limiter, unique}
    name = {:global, {__MODULE__, :blocked_server, unique}}

    limiter =
      start_supervised!(
        {EmergencyLimiter,
         name: name,
         key: key,
         interval: 1,
         poll_interval: 1,
         sink: {JournalAsh.TestEmergencySink, self()}}
      )

    assert :ok = EmergencyLimiter.enqueue(:full, key)
    assert_receive {:journal_ash_emergency_started, :full, ^limiter}

    Enum.each(1..1_000, fn _index -> EmergencyLimiter.enqueue(:unavailable, key) end)

    runtime = :persistent_term.get(key)
    assert :ets.info(runtime.queue, :size) == 1
    assert {:message_queue_len, 0} = Process.info(limiter, :message_queue_len)

    send(limiter, :release_journal_ash_emergency)
  end

  test "a failing emergency sink cannot crash the limiter" do
    unique = System.unique_integer([:positive, :monotonic])
    key = {__MODULE__, :failing_limiter, unique}
    name = {:global, {__MODULE__, :failing_server, unique}}

    limiter =
      start_supervised!(
        {EmergencyLimiter,
         name: name,
         key: key,
         interval: 1,
         poll_interval: 1,
         sink: {JournalAsh.TestEmergencySink, {:raise, self()}}}
      )

    assert :ok = EmergencyLimiter.enqueue(:full, key)
    assert_receive {:journal_ash_emergency_raise, :full}, 500
    assert Process.alive?(limiter)
    assert eventually(fn -> :ets.info(:persistent_term.get(key).queue, :size) == 0 end)
  end

  defp eventually(function, attempts \\ 50)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(2)
      eventually(function, attempts - 1)
    end
  end
end

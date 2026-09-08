defmodule JournalAsh.ApplicationTest do
  use ExUnit.Case, async: false

  alias JournalAsh.{Config, Intake, LoggerIntegration}

  test "a Logger filter collision tears down every newly started child" do
    unique = System.unique_integer([:positive, :monotonic])
    filter_id = :journal_ash_application_collision_test
    supervisor_name = {:global, {__MODULE__, :supervisor, unique}}
    emergency_name = {:global, {__MODULE__, :emergency, unique}}
    emergency_key = {__MODULE__, :emergency_runtime, unique}
    intake_name = {:global, {__MODULE__, :intake, unique}}
    store_name = {:global, {__MODULE__, :store, unique}}
    host_filter = {&JournalAsh.TestLoggerHandler.filter/2, %{owner: :host}}

    _removed = :logger.remove_primary_filter(filter_id)
    :ok = :logger.add_primary_filter(filter_id, host_filter)

    on_exit(fn ->
      :logger.remove_primary_filter(filter_id)
      :persistent_term.erase(LoggerIntegration.runtime_key(filter_id))
    end)

    configuration = %{
      Config.load()
      | install_logger_filter: true,
        logger_filter_id: filter_id,
        intake: intake_name,
        store: {JournalAsh.TestStore, [name: store_name]}
    }

    assert {:error, {:primary_filter, _reason}} =
             JournalAsh.Application.start_configuration(configuration,
               supervisor_name: supervisor_name,
               emergency_options: [name: emergency_name, key: emergency_key, sink: self()]
             )

    assert GenServer.whereis(supervisor_name) == nil
    assert GenServer.whereis(intake_name) == nil
    assert GenServer.whereis(emergency_name) == nil
    assert GenServer.whereis(store_name) == nil
    assert :persistent_term.get({Intake, intake_name}, :unavailable) == :unavailable
    assert :persistent_term.get(emergency_key, :unavailable) == :unavailable
    assert {^filter_id, ^host_filter} = find_primary_filter(filter_id)
    assert LoggerIntegration.health(configuration).primary_filter == :collision
  end

  test "an abnormal top-supervisor death leaves a reclaimable filter" do
    unique = System.unique_integer([:positive, :monotonic])
    filter_id = :journal_ash_abnormal_restart_test
    supervisor_name = {:global, {__MODULE__, :restart_supervisor, unique}}
    emergency_name = {:global, {__MODULE__, :restart_emergency, unique}}
    emergency_key = {__MODULE__, :restart_emergency_runtime, unique}
    intake_name = {:global, {__MODULE__, :restart_intake, unique}}
    store_name = {:global, {__MODULE__, :restart_store, unique}}

    configuration = %{
      Config.load()
      | install_logger_filter: true,
        logger_filter_id: filter_id,
        intake: intake_name,
        store: {JournalAsh.TestStore, [name: store_name]}
    }

    options = [
      supervisor_name: supervisor_name,
      emergency_options: [name: emergency_name, key: emergency_key, sink: self()]
    ]

    _removed = :logger.remove_primary_filter(filter_id)

    on_exit(fn ->
      :logger.remove_primary_filter(filter_id)
      :persistent_term.erase(LoggerIntegration.runtime_key(filter_id))
    end)

    assert {:ok, supervisor, _application_state} =
             JournalAsh.Application.start_configuration(configuration, options)

    stable_filter = find_primary_filter(filter_id)

    Process.unlink(supervisor)
    monitor = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}
    assert eventually(fn -> GenServer.whereis(intake_name) == nil end)
    assert eventually(fn -> GenServer.whereis(emergency_name) == nil end)
    assert eventually(fn -> GenServer.whereis(store_name) == nil end)
    assert LoggerIntegration.health(configuration).primary_filter == :stale

    assert {:ok, restarted_supervisor, restarted_state} =
             JournalAsh.Application.start_configuration(configuration, options)

    assert find_primary_filter(filter_id) == stable_filter

    assert %{primary_filter: :installed, primary_filter_order: :last} =
             LoggerIntegration.health(configuration)

    JournalAsh.Application.prep_stop(restarted_state)
    Supervisor.stop(restarted_supervisor)

    assert %{primary_filter: :inactive, primary_filter_order: :last} =
             LoggerIntegration.health(configuration)
  end

  defp find_primary_filter(filter_id) do
    List.keyfind(:logger.get_primary_config().filters, filter_id, 0)
  end

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
end

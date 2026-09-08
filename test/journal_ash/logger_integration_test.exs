defmodule JournalAsh.LoggerIntegrationTest do
  use ExUnit.Case, async: false

  require Logger

  alias JournalAsh.{Config, Decision, Internal, LoggerIntegration, PrimaryFilter}
  alias JournalAsh.Store.Memory

  defmodule JournalOnlyPolicy do
    @behaviour JournalAsh.Policy

    @impl true
    def decide(_envelope, _options) do
      %Decision{retention: :retain, projections: [], reason: :journal_only}
    end
  end

  defmodule BrokenPolicy do
    @behaviour JournalAsh.Policy

    @impl true
    def decide(_envelope, _options), do: raise("policy failure")
  end

  defmodule LoggingPolicy do
    @behaviour JournalAsh.Policy

    require Logger

    @impl true
    def decide(_envelope, _options) do
      Logger.info("policy evaluated", event: "journal.policy.evaluated")
      JournalAsh.Policy.Default.decide(nil, [])
    end
  end

  defmodule SelectiveStopFilter do
    def filter(%{meta: %{stop_before_journal: true}}, receiver) do
      send(receiver, :host_filter_stopped_event)
      :stop
    end

    def filter(event, _receiver), do: event
  end

  defmodule SelectiveRewriteFilter do
    def filter(%{meta: %{rewrite_before_journal: true} = metadata} = event, receiver) do
      send(receiver, :host_filter_rewrote_event)

      %{
        event
        | msg: {:string, "host-redacted"},
          meta:
            metadata
            |> Map.put(:event, "test.host_rewritten")
            |> Map.delete(:private_value)
      }
    end

    def filter(event, _receiver), do: event
  end

  setup do
    Memory.clear()
    :ok
  end

  test "an existing Logger call is retained without a JournalAsh facade" do
    configuration = configuration(:journal_ash_existing_logger_test)
    assert {:ok, installation} = LoggerIntegration.install(configuration)
    on_exit(fn -> remove_journal_filter(installation) end)

    Logger.info("task completed",
      event: "workflow.task.completed",
      password: "must-not-be-retained",
      journal_retention: :transient
    )

    assert :ok = JournalAsh.flush(1_000)

    assert [%{event: "workflow.task.completed"} = entry] = Memory.entries()
    refute Map.has_key?(entry.metadata, "password")
    refute Map.has_key?(entry.metadata, "journal_retention")
    assert entry.decision["retention"] == "retain"
  end

  test "central policy governs conventional Logger output globally" do
    event = logger_event("test.projection")

    assert :stop = PrimaryFilter.filter(event, filter_configuration(JournalOnlyPolicy))
    assert ^event = PrimaryFilter.filter(event, filter_configuration())
    assert :ok = JournalAsh.flush(1_000)
  end

  test "journal-only policy fails open when intake is unavailable or full" do
    event = logger_event("test.fail_open")

    unavailable = %{
      filter_configuration(JournalOnlyPolicy)
      | intake: {:global, {__MODULE__, :missing_intake}}
    }

    assert :ignore = PrimaryFilter.filter(event, unavailable)

    unique = System.unique_integer([:positive, :monotonic])
    store_name = {:global, {__MODULE__, :full_store, unique}}
    intake_name = {:global, {__MODULE__, :full_intake, unique}}

    start_supervised!({JournalAsh.TestStore, name: store_name, mode: :error})

    start_supervised!(
      {JournalAsh.Intake,
       name: intake_name,
       capacity: 1,
       sweep_interval: 60_000,
       store: {JournalAsh.TestStore, [name: store_name]}}
    )

    full = %{filter_configuration(JournalOnlyPolicy) | intake: intake_name}
    assert :stop = PrimaryFilter.filter(event, full)
    assert :ignore = PrimaryFilter.filter(event, full)
  end

  test "the filter never adds internal routing metadata visible to other handlers" do
    filter_id = :journal_ash_unmanaged_visibility_test
    handler_id = :journal_ash_unmanaged_handler_test
    _removed = :logger.remove_handler(handler_id)

    :ok =
      :logger.add_handler(handler_id, JournalAsh.TestLoggerHandler, %{
        level: :all,
        config: %{receiver: self()}
      })

    assert {:ok, installation} = LoggerIntegration.install(configuration(filter_id))

    on_exit(fn ->
      remove_journal_filter(installation)
      :logger.remove_handler(handler_id)
    end)

    Logger.info("visible", event: "test.unmanaged_visibility")

    assert_receive {:test_logger_event, %{meta: metadata}}
    refute Enum.any?(Map.keys(metadata), &(to_string(&1) =~ "journal_ash"))
    assert :ok = JournalAsh.flush(1_000)
  end

  test "policy failure preserves output and retains with the fallback decision" do
    event = logger_event("test.failure")

    assert ^event = PrimaryFilter.filter(event, filter_configuration(BrokenPolicy))
    assert :ok = JournalAsh.flush(1_000)

    assert [%{decision: decision}] = Memory.entries()
    assert decision["retention"] == "retain"
    assert decision["reason"] == "policy_failure"
  end

  test "a policy Logger call passes conventionally without recursively entering Journal" do
    configuration = configuration(:journal_ash_logging_policy_test, LoggingPolicy)
    assert {:ok, installation} = LoggerIntegration.install(configuration)
    on_exit(fn -> remove_journal_filter(installation) end)

    task = Task.async(fn -> Logger.info("outer event", event: "test.logging_policy") end)
    assert :ok = Task.await(task, 500)
    assert :ok = JournalAsh.flush(1_000)

    assert Enum.map(Memory.entries(), & &1.event) == ["test.logging_policy"]
  end

  test "internal journal work bypasses intake without hiding operational logs" do
    event = logger_event("journal.write")

    assert :ignore =
             Internal.run(fn -> PrimaryFilter.filter(event, filter_configuration()) end)

    assert :ok = JournalAsh.flush(1_000)
    assert Memory.entries() == []
  end

  test "uninstall deactivates its runtime and leaves its stable filter in place" do
    configuration = configuration(:journal_ash_lifecycle_test)
    assert {:ok, installation} = LoggerIntegration.install(configuration)
    on_exit(fn -> remove_journal_filter(installation) end)

    assert %{primary_filter: :installed, primary_filter_order: :last} =
             LoggerIntegration.health(configuration)

    stable_filter = find_primary_filter(configuration.logger_filter_id)

    assert :ok = LoggerIntegration.uninstall(installation)

    assert %{primary_filter: :inactive, primary_filter_order: :last} =
             LoggerIntegration.health(configuration)

    assert find_primary_filter(configuration.logger_filter_id) == stable_filter

    Logger.info("inactive runtime", event: "test.inactive_runtime")
    assert :ok = JournalAsh.flush(1_000)
    assert Memory.entries() == []

    assert {:ok, restarted_installation} = LoggerIntegration.install(configuration)
    assert find_primary_filter(configuration.logger_filter_id) == stable_filter
    assert :ok = LoggerIntegration.uninstall(restarted_installation)
  end

  test "an inert stable filter preserves the host's default-stop decision" do
    configuration = configuration(:journal_ash_inert_default_stop_test)
    handler_id = :journal_ash_inert_default_stop_handler_test
    previous = :logger.get_primary_config()
    assert {:ok, installation} = LoggerIntegration.install(configuration)
    stable_filter = find_primary_filter(configuration.logger_filter_id)

    on_exit(fn ->
      :logger.set_primary_config(previous)
      remove_journal_filter(installation)
      :logger.remove_handler(handler_id)
    end)

    :ok =
      :logger.add_handler(handler_id, JournalAsh.TestLoggerHandler, %{
        level: :all,
        config: %{receiver: self()}
      })

    assert :ok = LoggerIntegration.uninstall(installation)

    :ok =
      :logger.set_primary_config(%{previous | filters: [stable_filter], filter_default: :stop})

    assert %{
             primary_filter: :inactive,
             primary_filter_default: :stop,
             primary_filter_default_supported: false
           } = LoggerIntegration.health(configuration)

    :logger.info("inert default-stop", %{event: "test.inert_default_stop"})
    refute_receive {:test_logger_event, %{meta: %{event: "test.inert_default_stop"}}}

    :ok = :logger.set_primary_config(:filter_default, :log)
    :logger.info("inert default-log", %{event: "test.inert_default_log"})
    assert_receive {:test_logger_event, %{meta: %{event: "test.inert_default_log"}}}
  end

  test "installation rejects default-stop without changing host filters or runtime" do
    filter_id = :journal_ash_rejected_default_stop_test
    configuration = configuration(filter_id)
    previous_default = :logger.get_primary_config().filter_default
    previous_filters = :logger.get_primary_config().filters
    on_exit(fn -> :logger.set_primary_config(:filter_default, previous_default) end)

    :ok = :logger.set_primary_config(:filter_default, :stop)

    assert {:error, {:primary_filter, :unsupported_filter_default}} =
             LoggerIntegration.install(configuration)

    assert :logger.get_primary_config().filters == previous_filters
    assert :persistent_term.get(LoggerIntegration.runtime_key(filter_id), :missing) == :missing
  end

  test "reuses the stable filter while replacing a dead runtime owner" do
    filter_id = :journal_ash_runtime_reuse_test
    configuration = configuration(filter_id)
    owner = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, first_installation} = LoggerIntegration.install(configuration, owner)
    on_exit(fn -> remove_journal_filter(first_installation) end)
    stable_filter = find_primary_filter(filter_id)

    Process.exit(owner, :kill)
    assert eventually(fn -> not Process.alive?(owner) end)
    assert LoggerIntegration.health(configuration).primary_filter == :stale

    stale_event = logger_event("test.stale_runtime")

    assert :ignore =
             PrimaryFilter.filter(
               stale_event,
               {:journal_ash_runtime, first_installation.runtime_key}
             )

    assert :ok = JournalAsh.flush(1_000)
    assert Memory.entries() == []

    assert {:ok, second_installation} = LoggerIntegration.install(configuration)
    assert find_primary_filter(filter_id) == stable_filter

    assert %{primary_filter: :installed, primary_filter_order: :last} =
             LoggerIntegration.health(configuration)

    assert :ok = LoggerIntegration.uninstall(first_installation)
    assert LoggerIntegration.health(configuration).primary_filter == :installed

    assert :ok = LoggerIntegration.uninstall(second_installation)
    assert LoggerIntegration.health(configuration).primary_filter == :inactive
  end

  test "the stable Journal filter runs last and respects a preceding host stop" do
    journal_filter_id = :journal_ash_before_stop_order_test
    host_filter_id = :journal_ash_preceding_host_stop_test
    _removed = :logger.remove_primary_filter(host_filter_id)

    :ok =
      :logger.add_primary_filter(
        host_filter_id,
        {&SelectiveStopFilter.filter/2, self()}
      )

    configuration = configuration(journal_filter_id)
    assert {:ok, installation} = LoggerIntegration.install(configuration)

    on_exit(fn ->
      remove_journal_filter(installation)
      :logger.remove_primary_filter(host_filter_id)
    end)

    assert List.last(primary_filter_ids()) == journal_filter_id

    Logger.info("host will stop this",
      event: "test.preceding_host_stop",
      stop_before_journal: true
    )

    assert_receive :host_filter_stopped_event
    assert :ok = JournalAsh.flush(1_000)
    assert Memory.entries() == []
  end

  test "the built-in process-level filter can suppress an event before Journal" do
    journal_filter_id = :journal_ash_process_level_order_test
    configuration = configuration(journal_filter_id)
    assert {:ok, installation} = LoggerIntegration.install(configuration)
    previous_level = Logger.get_process_level(self())

    on_exit(fn ->
      restore_process_level(previous_level)
      remove_journal_filter(installation)
    end)

    :ok = Logger.put_process_level(self(), :error)
    Logger.info("suppressed", event: "test.process_level_suppressed")

    assert :ok = JournalAsh.flush(1_000)
    assert Memory.entries() == []
  end

  test "Journal observes the event after a preceding host rewrite" do
    journal_filter_id = :journal_ash_host_rewrite_order_test
    host_filter_id = :journal_ash_preceding_host_rewrite_test
    _removed = :logger.remove_primary_filter(host_filter_id)

    :ok =
      :logger.add_primary_filter(
        host_filter_id,
        {&SelectiveRewriteFilter.filter/2, self()}
      )

    configuration = configuration(journal_filter_id)
    assert {:ok, installation} = LoggerIntegration.install(configuration)

    on_exit(fn ->
      remove_journal_filter(installation)
      :logger.remove_primary_filter(host_filter_id)
    end)

    Logger.info("private original",
      event: "test.host_original",
      rewrite_before_journal: true,
      private_value: "remove-before-journal"
    )

    assert_receive :host_filter_rewrote_event
    assert :ok = JournalAsh.flush(1_000)

    assert [%{event: "test.host_rewritten", message: "host-redacted"} = entry] =
             Memory.entries()

    refute Map.has_key?(entry.metadata, "private_value")
  end

  test "later filters are prepended and leave the stable Journal filter last" do
    journal_filter_id = :journal_ash_later_filter_order_test
    host_filter_id = :journal_ash_later_host_filter_test
    configuration = configuration(journal_filter_id)
    assert {:ok, installation} = LoggerIntegration.install(configuration)

    :ok =
      :logger.add_primary_filter(
        host_filter_id,
        {&JournalAsh.TestLoggerHandler.filter/2, %{owner: :host}}
      )

    on_exit(fn ->
      :logger.remove_primary_filter(host_filter_id)
      remove_journal_filter(installation)
    end)

    assert List.first(primary_filter_ids()) == host_filter_id
    assert List.last(primary_filter_ids()) == journal_filter_id
    assert LoggerIntegration.health(configuration).primary_filter_order == :last
  end

  test "health reports a host-induced ordering violation separately from lifecycle" do
    journal_filter_id = :journal_ash_order_health_test
    host_filter_id = :journal_ash_trailing_host_filter_test
    configuration = configuration(journal_filter_id)
    assert {:ok, installation} = LoggerIntegration.install(configuration)

    filters = :logger.get_primary_config().filters
    journal_filter = List.keyfind(filters, journal_filter_id, 0)
    without_journal = List.keydelete(filters, journal_filter_id, 0)
    host_filter = {&JournalAsh.TestLoggerHandler.filter/2, %{owner: :host}}

    :ok =
      :logger.set_primary_config(
        :filters,
        without_journal ++ [journal_filter, {host_filter_id, host_filter}]
      )

    on_exit(fn ->
      :logger.remove_primary_filter(host_filter_id)
      remove_journal_filter(installation)
    end)

    assert %{primary_filter: :installed, primary_filter_order: :not_last} =
             LoggerIntegration.health(configuration)
  end

  test "concurrent installers serialize and only one live owner is activated" do
    filter_id = :journal_ash_concurrent_install_test
    configuration = configuration(filter_id)
    owners = Enum.map(1..8, fn _index -> spawn(fn -> Process.sleep(:infinity) end) end)

    results =
      owners
      |> Task.async_stream(
        &LoggerIntegration.install(configuration, &1),
        ordered: false,
        max_concurrency: length(owners)
      )
      |> Enum.map(fn {:ok, result} -> result end)

    installations = for {:ok, installation} <- results, do: installation

    on_exit(fn ->
      Enum.each(installations, &LoggerIntegration.uninstall/1)
      Enum.each(owners, &Process.exit(&1, :kill))
      :logger.remove_primary_filter(filter_id)
      :persistent_term.erase(LoggerIntegration.runtime_key(filter_id))
    end)

    assert length(installations) == 1

    assert Enum.count(primary_filter_ids(), &(&1 == filter_id)) == 1
    assert List.last(primary_filter_ids()) == filter_id

    assert Enum.count(results, &match?({:error, {:primary_filter, :already_active}}, &1)) == 7
  end

  test "installation preserves a host filter on identifier collision" do
    filter_id = :journal_ash_host_collision_test
    _removed = :logger.remove_primary_filter(filter_id)
    host_filter = {&JournalAsh.TestLoggerHandler.filter/2, %{owner: :host}}
    :ok = :logger.add_primary_filter(filter_id, host_filter)
    on_exit(fn -> :logger.remove_primary_filter(filter_id) end)

    configuration = configuration(filter_id)

    assert {:error, {:primary_filter, _reason}} = LoggerIntegration.install(configuration)
    assert {^filter_id, ^host_filter} = find_primary_filter(filter_id)
  end

  test "uninstall does not delete a host replacement using the same identifier" do
    filter_id = :journal_ash_host_replacement_test
    _removed = :logger.remove_primary_filter(filter_id)
    configuration = configuration(filter_id)

    assert {:ok, installation} = LoggerIntegration.install(configuration)
    :ok = :logger.remove_primary_filter(filter_id)

    host_filter = {&JournalAsh.TestLoggerHandler.filter/2, %{owner: :host}}
    :ok = :logger.add_primary_filter(filter_id, host_filter)

    on_exit(fn ->
      :logger.remove_primary_filter(filter_id)
      :persistent_term.erase(LoggerIntegration.runtime_key(filter_id))
    end)

    assert :ok = LoggerIntegration.uninstall(installation)
    assert {^filter_id, ^host_filter} = find_primary_filter(filter_id)
  end

  defp configuration(filter_id, policy \\ JournalAsh.Policy.Default) do
    %{
      Config.load()
      | install_logger_filter: true,
        logger_filter_id: filter_id,
        policy: policy
    }
  end

  defp filter_configuration(policy \\ JournalAsh.Policy.Default) do
    %{intake: JournalAsh.Intake, policy: policy, envelope: %{}}
  end

  defp logger_event(event) do
    %{level: :info, msg: {:string, "hello"}, meta: %{event: event}}
  end

  defp find_primary_filter(filter_id) do
    List.keyfind(:logger.get_primary_config().filters, filter_id, 0)
  end

  defp primary_filter_ids do
    Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))
  end

  defp remove_journal_filter(installation) do
    :ok = LoggerIntegration.uninstall(installation)
    :logger.remove_primary_filter(installation.configuration.logger_filter_id)
    :persistent_term.erase(installation.runtime_key)
    :ok
  end

  defp restore_process_level(previous_level) do
    if previous_level do
      Logger.put_process_level(self(), previous_level)
    else
      Logger.delete_process_level(self())
    end
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

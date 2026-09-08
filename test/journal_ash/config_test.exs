defmodule JournalAsh.ConfigTest do
  use ExUnit.Case, async: false

  alias JournalAsh.Config

  @keys [:install_logger_filter, :logger_filter_id, :store]

  setup do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:journal_ash, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:journal_ash, key, value)
        {key, :error} -> Application.delete_env(:journal_ash, key)
      end)
    end)

    :ok
  end

  test "an invalid store fails configuration instead of silently becoming volatile" do
    Application.put_env(:journal_ash, :store, String)

    assert_raise ArgumentError, ~r/does not implement JournalAsh.Store/, fn ->
      Config.load()
    end
  end

  test "the configured memory store must have an addressable process name" do
    Application.put_env(:journal_ash, :store, {JournalAsh.Store.Memory, [name: nil]})

    assert_raise ArgumentError, ~r/memory store requires a :name/, fn ->
      Config.load()
    end
  end

  test "Logger filter identifiers must be atoms" do
    Application.put_env(:journal_ash, :logger_filter_id, "journal_ash")

    assert_raise ArgumentError, ~r/logger_filter_id/, fn ->
      Config.load()
    end
  end

  test "overall health uses the configuration that the application actually started" do
    filter_id = :journal_ash_required_but_missing_test
    _removed = :logger.remove_primary_filter(filter_id)

    assert %{logger: %{primary_filter: :disabled}} = JournalAsh.health()

    Application.put_env(:journal_ash, :logger_filter_id, filter_id)
    Application.put_env(:journal_ash, :install_logger_filter, true)
    Application.put_env(:journal_ash, :store, String)

    assert %{logger: %{primary_filter: :disabled}} = JournalAsh.health()
    assert :ok = JournalAsh.flush(1_000)
  end
end

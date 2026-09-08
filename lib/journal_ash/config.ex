defmodule JournalAsh.Config do
  @moduledoc false

  @default_capacity 1_024
  @default_store_capacity 1_000

  @spec load() :: map()
  def load do
    store =
      :journal_ash
      |> Application.get_env(
        :store,
        {JournalAsh.Store.Memory,
         [name: JournalAsh.Store.Memory, max_entries: @default_store_capacity]}
      )
      |> normalize_store()

    logger_filter_id =
      :journal_ash
      |> Application.get_env(:logger_filter_id, :journal_ash)
      |> normalize_filter_id()

    %{
      install_logger_filter: Application.get_env(:journal_ash, :install_logger_filter, true),
      logger_filter_id: logger_filter_id,
      intake: Application.get_env(:journal_ash, :intake_name, JournalAsh.Intake),
      capacity: Application.get_env(:journal_ash, :capacity, @default_capacity),
      batch_size: Application.get_env(:journal_ash, :batch_size, 100),
      retry_interval: Application.get_env(:journal_ash, :retry_interval, 100),
      max_entry_attempts: Application.get_env(:journal_ash, :max_entry_attempts, 5),
      sweep_interval: Application.get_env(:journal_ash, :sweep_interval, 100),
      recent_drop_window: Application.get_env(:journal_ash, :recent_drop_window, 60_000),
      flush_timeout: Application.get_env(:journal_ash, :flush_timeout, 5_000),
      policy: Application.get_env(:journal_ash, :policy, JournalAsh.Policy.Default),
      envelope: %{
        limits: Application.get_env(:journal_ash, :limits, []),
        metadata_keys:
          Application.get_env(:journal_ash, :metadata_keys, JournalAsh.Envelope.metadata_keys()),
        capture_reports: Application.get_env(:journal_ash, :capture_reports, false)
      },
      store: store
    }
  end

  defp normalize_store({module, options}) when is_atom(module) and is_list(options),
    do: validate_store(module, options)

  defp normalize_store(module) when is_atom(module), do: validate_store(module, [])

  defp normalize_store(_invalid),
    do: raise(ArgumentError, "expected :journal_ash, :store to be a module or {module, options}")

  defp validate_store(module, options) do
    required = [child_spec: 1, append: 2, flush: 1, health: 1]

    if module == JournalAsh.Store.Memory and Keyword.get(options, :name, module) == nil do
      raise ArgumentError, "configured JournalAsh memory store requires a :name"
    end

    if Code.ensure_loaded?(module) and
         Enum.all?(required, fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      {module, options}
    else
      raise ArgumentError, "configured JournalAsh store does not implement JournalAsh.Store"
    end
  end

  defp normalize_filter_id(filter_id) when is_atom(filter_id), do: filter_id

  defp normalize_filter_id(_filter_id),
    do: raise(ArgumentError, "expected :journal_ash, :logger_filter_id to be an atom")
end

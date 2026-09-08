defmodule JournalAsh.LoggerIntegration.Installation do
  @moduledoc false

  @enforce_keys [:configuration, :filter_id, :owner_pid, :owner_token, :runtime_key]
  defstruct [:configuration, :filter_id, :owner_pid, :owner_token, :runtime_key]

  @type t :: %__MODULE__{
          configuration: map(),
          filter_id: atom(),
          owner_pid: pid(),
          owner_token: reference(),
          runtime_key: term()
        }
end

defmodule JournalAsh.LoggerIntegration do
  @moduledoc false

  alias JournalAsh.LoggerIntegration.Installation

  @inactive :inactive
  @runtime_marker :journal_ash_runtime

  @spec install(map(), pid()) :: {:ok, Installation.t()} | {:error, term()}
  def install(configuration, owner_pid \\ self()) when is_pid(owner_pid) do
    filter_id = configuration.logger_filter_id

    serialized(filter_id, fn ->
      owner_token = make_ref()
      runtime_key = runtime_key(filter_id)

      with :ok <- require_log_default(),
           :ok <- ensure_stable_filter(filter_id, runtime_key),
           :ok <- activate(runtime_key, configuration, owner_pid, owner_token) do
        {:ok,
         %Installation{
           configuration: configuration,
           filter_id: filter_id,
           owner_pid: owner_pid,
           owner_token: owner_token,
           runtime_key: runtime_key
         }}
      else
        {:error, reason} -> {:error, {:primary_filter, safe_reason(reason)}}
      end
    end)
  end

  @spec uninstall(Installation.t()) :: :ok
  def uninstall(%Installation{} = installation) do
    serialized(installation.filter_id, fn ->
      case :persistent_term.get(installation.runtime_key, @inactive) do
        %{owner_pid: owner_pid, owner_token: owner_token}
        when owner_pid == installation.owner_pid and
               owner_token == installation.owner_token ->
          :persistent_term.put(installation.runtime_key, @inactive)

        _inactive_or_replaced ->
          :ok
      end

      :ok
    end)
  end

  @spec health(map()) :: map()
  def health(%{install_logger_filter: false}) do
    %{
      primary_filter: :disabled,
      primary_filter_order: :disabled,
      primary_filter_default: :disabled,
      primary_filter_default_supported: true
    }
  end

  def health(configuration) do
    filter_id = configuration.logger_filter_id
    runtime_key = runtime_key(filter_id)
    primary_configuration = :logger.get_primary_config()
    filters = primary_configuration.filters

    case classify_filter(filters, filter_id, stable_filter(runtime_key)) do
      {:owned, index} ->
        %{
          primary_filter: runtime_status(runtime_key),
          primary_filter_order: if(index == length(filters) - 1, do: :last, else: :not_last)
        }

      :missing ->
        %{primary_filter: :missing, primary_filter_order: :missing}

      :collision ->
        %{primary_filter: :collision, primary_filter_order: :unknown}
    end
    |> Map.put(:primary_filter_default, primary_configuration.filter_default)
    |> Map.put(:primary_filter_default_supported, primary_configuration.filter_default == :log)
  end

  @doc false
  @spec runtime_key(atom()) :: term()
  def runtime_key(filter_id) when is_atom(filter_id),
    do: {__MODULE__, :runtime, filter_id}

  defp require_log_default do
    if :logger.get_primary_config().filter_default == :log,
      do: :ok,
      else: {:error, :unsupported_filter_default}
  end

  defp ensure_stable_filter(filter_id, runtime_key) do
    filter = stable_filter(runtime_key)

    case classify_filter(primary_filters(), filter_id, filter) do
      :missing ->
        case :logger.add_primary_filter(filter_id, filter) do
          :ok -> place_last(filter_id, filter)
          {:error, _reason} -> reuse_or_collision(filter_id, filter)
        end

      {:owned, _index} ->
        place_last(filter_id, filter)

      :collision ->
        {:error, :collision}
    end
  end

  defp reuse_or_collision(filter_id, filter) do
    case classify_filter(primary_filters(), filter_id, filter) do
      {:owned, _index} -> place_last(filter_id, filter)
      :missing -> {:error, :configuration_error}
      :collision -> {:error, :collision}
    end
  end

  defp place_last(filter_id, filter) do
    filters = primary_filters()

    case classify_filter(filters, filter_id, filter) do
      {:owned, index} when index == length(filters) - 1 ->
        :ok

      {:owned, _index} ->
        reordered = Enum.reject(filters, &(elem(&1, 0) == filter_id)) ++ [{filter_id, filter}]

        with :ok <- :logger.set_primary_config(:filters, reordered),
             latest_filters <- primary_filters(),
             {:owned, index} <- classify_filter(latest_filters, filter_id, filter),
             true <- index == length(latest_filters) - 1 do
          :ok
        else
          {:error, reason} -> {:error, reason}
          _changed_concurrently -> {:error, :ordering_failed}
        end

      :missing ->
        {:error, :missing}

      :collision ->
        {:error, :collision}
    end
  end

  defp activate(runtime_key, configuration, owner_pid, owner_token) do
    case :persistent_term.get(runtime_key, @inactive) do
      @inactive ->
        put_runtime(runtime_key, configuration, owner_pid, owner_token)

      %{owner_pid: existing_owner} when is_pid(existing_owner) ->
        if Process.alive?(existing_owner) do
          {:error, :already_active}
        else
          put_runtime(runtime_key, configuration, owner_pid, owner_token)
        end

      _invalid_runtime ->
        {:error, :runtime_collision}
    end
  end

  defp put_runtime(runtime_key, configuration, owner_pid, owner_token) do
    :persistent_term.put(runtime_key, %{
      owner_pid: owner_pid,
      owner_token: owner_token,
      configuration: %{
        intake: configuration.intake,
        policy: configuration.policy,
        envelope: configuration.envelope
      }
    })

    :ok
  end

  defp runtime_status(runtime_key) do
    case :persistent_term.get(runtime_key, @inactive) do
      @inactive ->
        :inactive

      %{
        owner_pid: owner_pid,
        owner_token: owner_token,
        configuration: %{intake: _intake, policy: _policy, envelope: _envelope}
      }
      when is_pid(owner_pid) and is_reference(owner_token) ->
        if Process.alive?(owner_pid), do: :installed, else: :stale

      _invalid_runtime ->
        :runtime_collision
    end
  end

  defp stable_filter(runtime_key) do
    {&JournalAsh.PrimaryFilter.filter/2, {@runtime_marker, runtime_key}}
  end

  defp classify_filter(filters, filter_id, expected_filter) do
    matches =
      filters
      |> Enum.with_index()
      |> Enum.filter(fn {{id, _filter}, _index} -> id == filter_id end)

    case matches do
      [{{^filter_id, ^expected_filter}, index}] -> {:owned, index}
      [] -> :missing
      _foreign_or_duplicated -> :collision
    end
  end

  defp primary_filters, do: :logger.get_primary_config().filters

  defp serialized(filter_id, function) do
    :global.trans({{__MODULE__, filter_id}, self()}, function, [node()])
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({reason, _detail}) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :configuration_error
end

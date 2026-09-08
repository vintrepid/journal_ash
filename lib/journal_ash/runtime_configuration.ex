defmodule JournalAsh.RuntimeConfiguration do
  @moduledoc false

  @key {__MODULE__, :active}

  @spec register(pid(), map()) :: :ok
  def register(owner, configuration) when is_pid(owner) and is_map(configuration) do
    serialized(fn -> :persistent_term.put(@key, {owner, configuration}) end)
  end

  @spec fetch() :: {:ok, map()} | :error
  def fetch do
    case :persistent_term.get(@key, :unavailable) do
      {owner, configuration} when is_pid(owner) and is_map(configuration) ->
        if Process.alive?(owner), do: {:ok, configuration}, else: :error

      _unavailable_or_invalid ->
        :error
    end
  end

  @spec unregister(pid()) :: :ok
  def unregister(owner) when is_pid(owner) do
    serialized(fn -> compare_and_erase(owner) end)
    :ok
  end

  defp compare_and_erase(owner) do
    case :persistent_term.get(@key, :unavailable) do
      {^owner, _configuration} -> :persistent_term.erase(@key)
      _different_owner_or_unavailable -> :ok
    end
  end

  defp serialized(function), do: :global.trans({@key, self()}, function, [node()])
end

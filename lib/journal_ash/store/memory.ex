defmodule JournalAsh.Store.Memory do
  @moduledoc """
  Strictly bounded, volatile store for tests and local evaluation.

  This adapter is intentionally not production durability. It retains the most
  recent entries up to `:max_entries` and forgets them when its process exits.
  """

  use GenServer

  alias JournalAsh.Entry

  @behaviour JournalAsh.Store

  @default_max_entries 1_000
  @hard_max_entries 4_096

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    case name(options) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def child_spec(options) do
    %{
      id: {__MODULE__, name(options) || make_ref()},
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @impl true
  def append(%Entry{} = entry, options) do
    GenServer.call(name(options), {:append, entry})
  end

  @impl true
  def flush(options), do: GenServer.call(name(options), :flush)

  @impl true
  def health(options), do: GenServer.call(name(options), :health)

  @doc "Returns retained entries oldest first. Intended for tests and local inspection."
  @spec entries(keyword()) :: [Entry.t()]
  def entries(options \\ []), do: GenServer.call(name(options), :entries)

  @doc false
  @spec clear(keyword()) :: :ok
  def clear(options \\ []), do: GenServer.call(name(options), :clear)

  @impl true
  def init(options) do
    maximum = bounded_maximum(Keyword.get(options, :max_entries, @default_max_entries))
    {:ok, %{entries: %{}, order: :queue.new(), max_entries: maximum}}
  end

  @impl true
  def handle_call({:append, %Entry{} = entry}, _from, state) do
    state =
      if Map.has_key?(state.entries, entry.id) do
        state
      else
        state
        |> put_in([:entries, entry.id], entry)
        |> Map.update!(:order, &:queue.in(entry.id, &1))
        |> trim_oldest()
      end

    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call(:health, _from, state) do
    health = %{
      status: :ready,
      durability: :volatile,
      retained: map_size(state.entries),
      capacity: state.max_entries
    }

    {:reply, health, state}
  end

  def handle_call(:entries, _from, state) do
    entries = state.order |> :queue.to_list() |> Enum.map(&Map.fetch!(state.entries, &1))
    {:reply, entries, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: %{}, order: :queue.new()}}
  end

  defp trim_oldest(state) when map_size(state.entries) <= state.max_entries, do: state

  defp trim_oldest(state) do
    {{:value, oldest_id}, order} = :queue.out(state.order)
    %{state | entries: Map.delete(state.entries, oldest_id), order: order}
  end

  defp name(options), do: Keyword.get(options, :name, __MODULE__)

  defp bounded_maximum(value) when is_integer(value) and value > 0,
    do: min(value, @hard_max_entries)

  defp bounded_maximum(_value), do: @default_max_entries
end

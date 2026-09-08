defmodule JournalAsh.Limits do
  @moduledoc """
  Hard bounds applied before a Logger event enters the journal queue.

  Host configuration may lower these values. It cannot raise them beyond the
  library's hard ceilings, so a configuration error cannot turn journal intake
  into an unbounded allocation path.
  """

  @default_message_bytes 4_096
  @default_metadata_entries 32
  @default_collection_items 32
  @default_depth 4
  @default_total_nodes 64
  @default_total_bytes 32_768

  @hard_message_bytes 8_192
  @hard_metadata_entries 64
  @hard_collection_items 32
  @hard_depth 6
  @hard_total_nodes 64
  @hard_total_bytes 32_768

  defstruct max_message_bytes: @default_message_bytes,
            max_metadata_entries: @default_metadata_entries,
            max_collection_items: @default_collection_items,
            max_depth: @default_depth,
            max_total_nodes: @default_total_nodes,
            max_total_bytes: @default_total_bytes

  @type t :: %__MODULE__{
          max_message_bytes: pos_integer(),
          max_metadata_entries: pos_integer(),
          max_collection_items: pos_integer(),
          max_depth: pos_integer(),
          max_total_nodes: pos_integer(),
          max_total_bytes: pos_integer()
        }

  @spec new(keyword() | map() | t()) :: t()
  def new(%__MODULE__{} = limits), do: limits |> Map.from_struct() |> new()

  def new(options) when is_map(options) do
    %__MODULE__{
      max_message_bytes:
        bounded(Map.get(options, :max_message_bytes), @default_message_bytes, @hard_message_bytes),
      max_metadata_entries:
        bounded(
          Map.get(options, :max_metadata_entries),
          @default_metadata_entries,
          @hard_metadata_entries
        ),
      max_collection_items:
        bounded(
          Map.get(options, :max_collection_items),
          @default_collection_items,
          @hard_collection_items
        ),
      max_depth: bounded(Map.get(options, :max_depth), @default_depth, @hard_depth),
      max_total_nodes:
        bounded(Map.get(options, :max_total_nodes), @default_total_nodes, @hard_total_nodes),
      max_total_bytes:
        bounded(Map.get(options, :max_total_bytes), @default_total_bytes, @hard_total_bytes)
    }
  end

  def new(options) when is_list(options) do
    options
    |> take_options(16, [])
    |> Map.new()
    |> new()
  end

  def new(_options), do: %__MODULE__{}

  @doc false
  @spec hard() :: t()
  def hard do
    %__MODULE__{
      max_message_bytes: @hard_message_bytes,
      max_metadata_entries: @hard_metadata_entries,
      max_collection_items: @hard_collection_items,
      max_depth: @hard_depth,
      max_total_nodes: @hard_total_nodes,
      max_total_bytes: @hard_total_bytes
    }
  end

  defp bounded(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded(_value, default, _maximum), do: default

  defp take_options(_options, 0, result), do: Enum.reverse(result)
  defp take_options([], _remaining, result), do: Enum.reverse(result)

  defp take_options([{key, value} | rest], remaining, result) when is_atom(key),
    do: take_options(rest, remaining - 1, [{key, value} | result])

  defp take_options([_invalid | rest], remaining, result),
    do: take_options(rest, remaining - 1, result)

  defp take_options(_improper, _remaining, result), do: Enum.reverse(result)
end

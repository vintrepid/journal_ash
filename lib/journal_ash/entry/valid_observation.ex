defmodule JournalAsh.Entry.ValidObservation do
  @moduledoc false

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges
  alias JournalAsh.{Limits, Sanitizer}

  @minimum_integer -9_223_372_036_854_775_808
  @maximum_integer 9_223_372_036_854_775_807
  @retentions ["retain", "transient"]
  @projections ["standard_log", "telemetry"]

  @impl true
  def validate(changeset, _options, _context) do
    message = Ash.Changeset.get_attribute(changeset, :message)
    metadata = Ash.Changeset.get_attribute(changeset, :metadata)
    decision = Ash.Changeset.get_attribute(changeset, :decision)

    with :ok <- validate_values(message, metadata, decision) do
      :ok
    else
      {:error, field, error_message} ->
        {:error, InvalidChanges.exception(fields: [field], message: error_message)}
    end
  end

  @doc false
  @spec validate_values(term(), term(), term()) ::
          :ok | {:error, :message | :metadata | :decision, String.t()}
  def validate_values(message, metadata, decision) do
    with :ok <- validate_metadata(message, metadata),
         :ok <- validate_decision(decision) do
      :ok
    end
  end

  defp validate_metadata(message, metadata) when is_binary(message) and is_map(metadata) do
    limits = Limits.hard()
    remaining_bytes = limits.max_total_bytes - byte_size(message)

    cond do
      byte_size(message) > limits.max_message_bytes ->
        {:error, :message, "exceeds the journal message byte limit"}

      not String.valid?(message) ->
        {:error, :message, "must be valid UTF-8"}

      remaining_bytes < 0 ->
        {:error, :message, "exceeds the journal hard byte limit"}

      Sanitizer.metadata(metadata, :all, limits, remaining_bytes) !== metadata ->
        {:error, :metadata, "must already be canonical, sanitized journal metadata"}

      not metadata_within_bounds?(metadata, byte_size(message), limits) ->
        {:error, :metadata, "exceeds the journal hard structural limits"}

      true ->
        :ok
    end
  end

  defp validate_metadata(_message, _metadata),
    do: {:error, :metadata, "must be canonical journal metadata"}

  defp validate_decision(
         %{
           "retention" => retention,
           "projections" => projections,
           "reason" => reason
         } = decision
       )
       when map_size(decision) == 3 do
    if retention in @retentions and valid_projections?(projections) and valid_reason?(reason) do
      :ok
    else
      {:error, :decision, "must be a canonical journal decision"}
    end
  end

  defp validate_decision(_decision),
    do: {:error, :decision, "must be a canonical journal decision"}

  defp valid_projections?([]), do: true
  defp valid_projections?([projection]), do: projection in @projections

  defp valid_projections?([first, second]),
    do: first in @projections and second in @projections and first != second

  defp valid_projections?(_projections), do: false

  defp valid_reason?(nil), do: true

  defp valid_reason?(reason) when is_binary(reason),
    do: byte_size(reason) <= 160 and String.valid?(reason)

  defp valid_reason?(_reason), do: false

  defp metadata_within_bounds?(metadata, initial_bytes, limits) do
    if map_size(metadata) <= limits.max_metadata_entries do
      case walk_pairs(Map.to_list(metadata), 1, %{nodes: 0, bytes: initial_bytes}, limits) do
        {:ok, _state} -> true
        :error -> false
      end
    else
      false
    end
  end

  defp walk_pairs([], _depth, state, _limits), do: {:ok, state}

  defp walk_pairs([{key, value} | rest], depth, state, limits) do
    with true <- is_binary(key) and String.valid?(key),
         {:ok, state} <- spend(state, 1, byte_size(key), limits),
         {:ok, state} <- walk_value(value, depth, state, limits) do
      walk_pairs(rest, depth, state, limits)
    else
      _invalid -> :error
    end
  end

  defp walk_value(_value, depth, _state, limits) when depth > limits.max_depth, do: :error

  defp walk_value(value, _depth, state, limits) when is_nil(value) or is_boolean(value),
    do: spend(state, 1, 0, limits)

  defp walk_value(value, _depth, state, limits)
       when is_integer(value) and value >= @minimum_integer and value <= @maximum_integer,
       do: spend(state, 1, 0, limits)

  defp walk_value(value, _depth, state, limits) when is_float(value) do
    if finite_float?(value), do: spend(state, 1, 0, limits), else: :error
  end

  defp walk_value(value, _depth, state, limits) when is_binary(value) do
    if String.valid?(value) do
      spend(state, 1, byte_size(value), limits)
    else
      :error
    end
  end

  defp walk_value(value, depth, state, limits) when is_map(value) do
    if map_size(value) <= limits.max_collection_items do
      with {:ok, state} <- spend(state, 1, 0, limits) do
        walk_pairs(Map.to_list(value), depth + 1, state, limits)
      end
    else
      :error
    end
  end

  defp walk_value(value, depth, state, limits) when is_list(value) do
    with {:ok, state} <- spend(state, 1, 0, limits),
         {:ok, values} <- bounded_proper_list(value, limits.max_collection_items) do
      walk_values(values, depth + 1, state, limits)
    end
  end

  defp walk_value(_value, _depth, _state, _limits), do: :error

  defp walk_values([], _depth, state, _limits), do: {:ok, state}

  defp walk_values([value | rest], depth, state, limits) do
    with {:ok, state} <- walk_value(value, depth, state, limits) do
      walk_values(rest, depth, state, limits)
    end
  end

  defp bounded_proper_list(list, maximum), do: bounded_proper_list(list, maximum, [])
  defp bounded_proper_list([], _remaining, result), do: {:ok, Enum.reverse(result)}
  defp bounded_proper_list([_head | _tail], 0, _result), do: :error

  defp bounded_proper_list([head | tail], remaining, result),
    do: bounded_proper_list(tail, remaining - 1, [head | result])

  defp bounded_proper_list(_improper, _remaining, _result), do: :error

  defp spend(state, nodes, bytes, limits) do
    state = %{nodes: state.nodes + nodes, bytes: state.bytes + bytes}

    if state.nodes <= limits.max_total_nodes and state.bytes <= limits.max_total_bytes do
      {:ok, state}
    else
      :error
    end
  end

  defp finite_float?(value), do: value == value and abs(value) <= 1.7976931348623157e308
end

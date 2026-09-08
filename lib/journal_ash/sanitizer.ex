defmodule JournalAsh.Sanitizer do
  @moduledoc false

  alias JournalAsh.Limits

  @redacted "[REDACTED]"
  @depth_limit "[DEPTH_LIMIT]"
  @unsupported "[UNSUPPORTED_VALUE]"
  @maximum_chardata_nodes 1_024
  @maximum_key_chardata_nodes 512
  @maximum_key_bytes 160
  @minimum_integer -9_223_372_036_854_775_808
  @maximum_integer 9_223_372_036_854_775_807

  @sensitive_fragments [
    "access-key",
    "access_key",
    "accesskey",
    "api-key",
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "credential",
    "passphrase",
    "passwd",
    "password",
    "private-key",
    "private_key",
    "privatekey",
    "secret",
    "session",
    "token"
  ]

  @producer_policy_keys MapSet.new([
                          "alert",
                          "alert?",
                          "decision",
                          "journal",
                          "journal?",
                          "journal_retention",
                          "log?",
                          "policy",
                          "policy_version",
                          "projections",
                          "retain?",
                          "retention",
                          "retention_class",
                          "sinks",
                          "standard_log?",
                          "telemetry?",
                          "text?"
                        ])

  @type budget :: %{nodes: non_neg_integer(), bytes: non_neg_integer()}

  @spec metadata(map(), :all | [atom() | String.t()], Limits.t(), non_neg_integer()) :: map()
  def metadata(metadata, allowed_keys, limits, byte_budget \\ nil)

  def metadata(metadata, allowed_keys, %Limits{} = limits, byte_budget)
      when is_map(metadata) do
    budget = %{
      nodes: limits.max_total_nodes,
      bytes: bounded_byte_budget(byte_budget, limits.max_total_bytes)
    }

    metadata
    |> selected_metadata(allowed_keys, limits.max_metadata_entries)
    |> sanitize_pairs(limits, limits.max_depth, budget)
    |> elem(0)
  end

  def metadata(_metadata, _allowed_keys, _limits, _byte_budget), do: %{}

  @spec value(term(), Limits.t()) :: term()
  def value(value, %Limits{} = limits) do
    value
    |> sanitize_value(limits, limits.max_depth, %{
      nodes: limits.max_total_nodes,
      bytes: limits.max_total_bytes
    })
    |> elem(0)
  end

  @spec text(term(), pos_integer()) :: String.t()
  def text(binary, maximum_bytes) when is_binary(binary) and maximum_bytes > 0 do
    cond do
      byte_size(binary) <= maximum_bytes and String.valid?(binary) ->
        :binary.copy(binary)

      byte_size(binary) <= maximum_bytes ->
        truncate_utf8(@unsupported, maximum_bytes)

      true ->
        truncate_utf8(binary, maximum_bytes)
    end
  end

  def text(chardata, maximum_bytes) when is_list(chardata) and maximum_bytes > 0 do
    {chunks, status} =
      consume_chardata([chardata], [], maximum_bytes, @maximum_chardata_nodes)

    result = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> :binary.copy()

    case status do
      :complete -> result
      :has_marker -> result
      :needs_marker -> append_marker(result, maximum_bytes)
    end
  rescue
    _error -> truncate_utf8(@unsupported, maximum_bytes)
  end

  def text(_value, maximum_bytes) when is_integer(maximum_bytes) and maximum_bytes > 0,
    do: truncate_utf8(@unsupported, maximum_bytes)

  def text(_value, _maximum_bytes), do: ""

  defp selected_metadata(metadata, :all, maximum_entries),
    do: bounded_map_pairs(metadata, maximum_entries, false)

  defp selected_metadata(metadata, allowed_keys, maximum_entries) when is_list(allowed_keys) do
    allowed_keys
    |> take_list(maximum_entries)
    |> Enum.reduce([], fn allowed_key, selected ->
      case fetch_allowed(metadata, allowed_key) do
        {:ok, key, value} -> [{key, value} | selected]
        :error -> selected
      end
    end)
    |> Enum.reverse()
  end

  defp selected_metadata(_metadata, _allowed_keys, _maximum_entries), do: []

  defp fetch_allowed(metadata, key) when is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> {:ok, key, value}
      :error -> fetch_allowed(metadata, Atom.to_string(key))
    end
  end

  defp fetch_allowed(metadata, key) when is_binary(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> {:ok, key, value}
      :error -> :error
    end
  end

  defp fetch_allowed(_metadata, _key), do: :error

  defp sanitize_pairs(pairs, limits, depth, budget) do
    Enum.reduce_while(pairs, {%{}, budget}, fn {key, nested_value}, {result, budget} ->
      if exhausted?(budget) do
        {:halt, {result, budget}}
      else
        budget = spend_node(budget)

        case key_name(key) do
          nil ->
            {:cont, {result, budget}}

          name ->
            cond do
              producer_policy_key?(name) ->
                {:cont, {result, budget}}

              sensitive_key?(name) ->
                case retain_key(name, budget) do
                  {nil, budget} ->
                    {:cont, {result, budget}}

                  {name, budget} ->
                    if exhausted?(budget) do
                      {:cont, {result, budget}}
                    else
                      {redacted, budget} = output_placeholder(@redacted, limits, budget)
                      {:cont, {Map.put(result, name, redacted), budget}}
                    end
                end

              true ->
                case retain_key(name, budget) do
                  {nil, budget} ->
                    {:cont, {result, budget}}

                  {name, budget} ->
                    if exhausted?(budget) do
                      {:cont, {result, budget}}
                    else
                      {sanitized, budget} =
                        sanitize_value(nested_value, limits, depth - 1, budget)

                      {:cont, {Map.put(result, name, sanitized), budget}}
                    end
                end
            end
        end
      end
    end)
  end

  defp sanitize_value(_value, _limits, _depth, budget) when budget.nodes <= 0,
    do: {nil, budget}

  defp sanitize_value(_value, _limits, _depth, budget) when budget.bytes <= 0,
    do: {nil, budget}

  defp sanitize_value(_value, limits, depth, budget) when depth <= 0 do
    budget = spend_node(budget)
    output_text(@depth_limit, limits, budget)
  end

  defp sanitize_value(nil, _limits, _depth, budget), do: {nil, spend_scalar(budget)}

  defp sanitize_value(value, _limits, _depth, budget) when is_boolean(value),
    do: {value, spend_scalar(budget)}

  defp sanitize_value(value, _limits, _depth, budget)
       when is_integer(value) and value >= @minimum_integer and value <= @maximum_integer,
       do: {value, spend_scalar(budget)}

  defp sanitize_value(value, limits, _depth, budget) when is_integer(value),
    do: output_placeholder("[INTEGER_OUT_OF_RANGE]", limits, budget)

  defp sanitize_value(value, _limits, _depth, budget) when is_float(value),
    do: {value, spend_scalar(budget)}

  defp sanitize_value(value, limits, _depth, budget) when is_atom(value) do
    budget = spend_node(budget)
    output_text(Atom.to_string(value), limits, budget)
  end

  defp sanitize_value(value, %Limits{} = limits, _depth, budget) when is_binary(value) do
    budget = spend_node(budget)
    output_text(value, limits, budget)
  end

  defp sanitize_value(%module{} = struct, %Limits{} = limits, depth, budget) do
    budget = spend_node(budget)

    pairs =
      [
        {:__type__, Atom.to_string(module)}
        | bounded_map_pairs(struct, max(limits.max_collection_items - 1, 0), true)
      ]

    sanitize_pairs(pairs, limits, depth, budget)
  end

  defp sanitize_value({key, nested_value}, %Limits{} = limits, depth, budget)
       when is_atom(key) or is_binary(key) or is_integer(key) or is_list(key) do
    budget = spend_node(budget)
    sanitize_pairs([{key, nested_value}], limits, depth, budget)
  end

  defp sanitize_value(value, %Limits{} = limits, depth, budget) when is_map(value) do
    budget = spend_node(budget)

    value
    |> bounded_map_pairs(limits.max_collection_items, false)
    |> sanitize_pairs(limits, depth, budget)
  end

  defp sanitize_value(value, %Limits{} = limits, depth, budget) when is_list(value) do
    budget = spend_node(budget)

    value
    |> take_list(limits.max_collection_items)
    |> sanitize_values(limits, depth - 1, budget)
  end

  defp sanitize_value(value, %Limits{} = limits, depth, budget) when is_tuple(value) do
    budget = spend_node(budget)

    value
    |> take_tuple(limits.max_collection_items)
    |> sanitize_values(limits, depth - 1, budget)
  end

  defp sanitize_value(value, limits, _depth, budget) when is_pid(value),
    do: output_placeholder("[PID]", limits, budget)

  defp sanitize_value(value, limits, _depth, budget) when is_reference(value),
    do: output_placeholder("[REFERENCE]", limits, budget)

  defp sanitize_value(value, limits, _depth, budget) when is_port(value),
    do: output_placeholder("[PORT]", limits, budget)

  defp sanitize_value(value, limits, _depth, budget) when is_function(value),
    do: output_placeholder("[FUNCTION]", limits, budget)

  defp sanitize_value(_value, limits, _depth, budget),
    do: output_placeholder(@unsupported, limits, budget)

  defp sanitize_values(values, limits, depth, budget) do
    Enum.reduce_while(values, {[], budget}, fn value, {result, budget} ->
      if exhausted?(budget) do
        {:halt, {result, budget}}
      else
        {sanitized, budget} = sanitize_value(value, limits, depth, budget)
        {:cont, {[sanitized | result], budget}}
      end
    end)
    |> then(fn {reversed, budget} -> {Enum.reverse(reversed), budget} end)
  end

  defp output_placeholder(placeholder, limits, budget) do
    budget = spend_node(budget)
    output_text(placeholder, limits, budget)
  end

  defp output_text(value, limits, budget) do
    maximum = min(limits.max_message_bytes, budget.bytes)
    output = text(value, maximum)
    {output, %{budget | bytes: budget.bytes - byte_size(output)}}
  end

  defp key_name(key) when is_atom(key), do: key |> Atom.to_string() |> key_name()

  defp key_name(key) when is_binary(key) and byte_size(key) <= @maximum_key_bytes do
    if String.valid?(key), do: key
  end

  defp key_name(key) when is_list(key) do
    case consume_key_chardata(
           [key],
           [],
           @maximum_key_bytes,
           @maximum_key_chardata_nodes
         ) do
      {:ok, chunks} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      :error -> nil
    end
  end

  defp key_name(key)
       when is_integer(key) and key >= @minimum_integer and key <= @maximum_integer,
       do: Integer.to_string(key)

  defp key_name(key) when is_integer(key), do: "[INTEGER_KEY_OUT_OF_RANGE]"

  defp key_name(_key), do: nil

  defp retain_key(key, budget) do
    if byte_size(key) <= budget.bytes do
      {:binary.copy(key), %{budget | bytes: budget.bytes - byte_size(key)}}
    else
      {nil, budget}
    end
  end

  defp sensitive_key?(key) do
    downcased = String.downcase(key)
    Enum.any?(@sensitive_fragments, &String.contains?(downcased, &1))
  end

  defp producer_policy_key?(key) do
    downcased = String.downcase(key)

    MapSet.member?(@producer_policy_keys, downcased) or
      String.starts_with?(downcased, "journal_ash")
  end

  defp bounded_map_pairs(map, maximum, skip_struct?) do
    map
    |> :maps.iterator()
    |> take_map_pairs(maximum, skip_struct?, [])
    |> Enum.reverse()
  end

  defp take_map_pairs(_iterator, 0, _skip_struct?, result), do: result

  defp take_map_pairs(iterator, remaining, skip_struct?, result) do
    case :maps.next(iterator) do
      :none ->
        result

      {:__struct__, _module, next_iterator} when skip_struct? ->
        take_map_pairs(next_iterator, remaining, skip_struct?, result)

      {key, value, next_iterator} ->
        take_map_pairs(next_iterator, remaining - 1, skip_struct?, [{key, value} | result])
    end
  end

  defp take_list(list, maximum), do: take_list(list, maximum, [])
  defp take_list(_list, 0, result), do: Enum.reverse(result)
  defp take_list([], _remaining, result), do: Enum.reverse(result)

  defp take_list([head | tail], remaining, result),
    do: take_list(tail, remaining - 1, [head | result])

  defp take_list(_improper_tail, _remaining, result), do: Enum.reverse(result)

  defp take_tuple(tuple, maximum) do
    tuple
    |> tuple_indexes(maximum)
    |> Enum.map(&elem(tuple, &1))
  end

  defp consume_key_chardata([], chunks, _remaining_bytes, _remaining_nodes),
    do: {:ok, chunks}

  defp consume_key_chardata(_stack, _chunks, _remaining_bytes, 0), do: :error

  defp consume_key_chardata([[] | stack], chunks, remaining_bytes, remaining_nodes),
    do: consume_key_chardata(stack, chunks, remaining_bytes, remaining_nodes - 1)

  defp consume_key_chardata([[head | tail] | stack], chunks, remaining_bytes, remaining_nodes),
    do:
      consume_key_chardata(
        [head, tail | stack],
        chunks,
        remaining_bytes,
        remaining_nodes - 1
      )

  defp consume_key_chardata([binary | stack], chunks, remaining_bytes, remaining_nodes)
       when is_binary(binary) do
    if byte_size(binary) <= remaining_bytes and String.valid?(binary) do
      consume_key_chardata(
        stack,
        [binary | chunks],
        remaining_bytes - byte_size(binary),
        remaining_nodes - 1
      )
    else
      :error
    end
  end

  defp consume_key_chardata([codepoint | stack], chunks, remaining_bytes, remaining_nodes)
       when is_integer(codepoint) and codepoint >= 0 and codepoint <= 0x10FFFF and
              codepoint not in 0xD800..0xDFFF do
    binary = <<codepoint::utf8>>

    if byte_size(binary) <= remaining_bytes do
      consume_key_chardata(
        stack,
        [binary | chunks],
        remaining_bytes - byte_size(binary),
        remaining_nodes - 1
      )
    else
      :error
    end
  end

  defp consume_key_chardata(_stack, _chunks, _remaining_bytes, _remaining_nodes), do: :error

  defp tuple_indexes(tuple, maximum) do
    case min(tuple_size(tuple), maximum) do
      0 -> []
      size -> Enum.to_list(0..(size - 1))
    end
  end

  defp consume_chardata([], chunks, _remaining_bytes, _remaining_nodes),
    do: {chunks, :complete}

  defp consume_chardata(_stack, chunks, _remaining_bytes, 0),
    do: {chunks, :needs_marker}

  defp consume_chardata(_stack, chunks, remaining_bytes, _remaining_nodes)
       when remaining_bytes <= 0,
       do: {chunks, :needs_marker}

  defp consume_chardata([[] | stack], chunks, remaining_bytes, remaining_nodes),
    do: consume_chardata(stack, chunks, remaining_bytes, remaining_nodes - 1)

  defp consume_chardata([[head | tail] | stack], chunks, remaining_bytes, remaining_nodes),
    do: consume_chardata([head, tail | stack], chunks, remaining_bytes, remaining_nodes - 1)

  defp consume_chardata([binary | stack], chunks, remaining_bytes, remaining_nodes)
       when is_binary(binary) do
    if byte_size(binary) <= remaining_bytes and String.valid?(binary) do
      consume_chardata(
        stack,
        [binary | chunks],
        remaining_bytes - byte_size(binary),
        remaining_nodes - 1
      )
    else
      {[truncate_utf8(binary, remaining_bytes) | chunks], :has_marker}
    end
  end

  defp consume_chardata([codepoint | stack], chunks, remaining_bytes, remaining_nodes)
       when is_integer(codepoint) and codepoint >= 0 and codepoint <= 0x10FFFF and
              codepoint not in 0xD800..0xDFFF do
    consume_chardata(
      [<<codepoint::utf8>> | stack],
      chunks,
      remaining_bytes,
      remaining_nodes - 1
    )
  end

  defp consume_chardata([_unsupported | stack], chunks, remaining_bytes, remaining_nodes) do
    consume_chardata(
      [@unsupported | stack],
      chunks,
      remaining_bytes,
      remaining_nodes - 1
    )
  end

  defp truncate_utf8(_binary, maximum_bytes) when maximum_bytes <= 0, do: ""

  defp truncate_utf8(_binary, maximum_bytes) when maximum_bytes <= 3,
    do: binary_part("...", 0, maximum_bytes)

  defp truncate_utf8(binary, maximum_bytes) do
    prefix_bytes = min(byte_size(binary), maximum_bytes - 3)

    prefix = binary_part(binary, 0, prefix_bytes)
    valid_utf8_prefix(prefix) <> "..."
  end

  defp append_marker(binary, maximum_bytes) when byte_size(binary) <= maximum_bytes - 3,
    do: binary <> "..."

  defp append_marker(binary, maximum_bytes), do: truncate_utf8(binary, maximum_bytes)

  defp valid_utf8_prefix(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:error, valid, _invalid_rest} -> valid
      {:incomplete, valid, _incomplete_rest} -> valid
    end
  rescue
    _error -> ""
  catch
    _kind, _reason -> ""
  end

  defp spend_node(budget), do: %{budget | nodes: max(budget.nodes - 1, 0)}

  defp spend_scalar(budget) do
    budget
    |> spend_node()
    |> Map.update!(:bytes, &max(&1 - 16, 0))
  end

  defp exhausted?(budget), do: budget.nodes <= 0 or budget.bytes <= 0

  defp bounded_byte_budget(nil, maximum), do: maximum

  defp bounded_byte_budget(value, maximum) when is_integer(value) and value >= 0,
    do: min(value, maximum)

  defp bounded_byte_budget(_value, maximum), do: maximum
end

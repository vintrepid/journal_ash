defmodule JournalAsh.EnvelopePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JournalAsh.{Decision, Entry, Envelope, Limits}

  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  defmodule LargeStruct do
    @moduledoc false
    defstruct Enum.map(1..40, &String.to_atom("field_#{&1}"))
  end

  property "arbitrary Logger terms always produce a bounded canonical observation" do
    check all(
            message <- StreamData.term(),
            metadata <- StreamData.map_of(StreamData.term(), StreamData.term(), max_length: 48),
            level <- StreamData.member_of(@levels),
            max_runs: 100
          ) do
      assert {:ok, envelope} =
               Envelope.from_logger(
                 %{level: level, msg: message, meta: metadata},
                 capture_reports: true,
                 metadata_keys: :all,
                 limits: Limits.hard()
               )

      assert_bounded(envelope)

      assert {:ok, %Entry{}} =
               Entry.from_observation(envelope, %Decision{
                 retention: :retain,
                 projections: [:standard_log, :telemetry]
               })
    end
  end

  test "adversarial Logger values never inspect, raise, or escape hard bounds" do
    deeply_nested = Enum.reduce(1..100, "bottom", fn _, nested -> [nested] end)
    improper = ["head" | "improper-tail"]
    huge_map = Map.new(1..5_000, &{"key-#{&1}", String.duplicate("v", 1_000)})

    values = [
      <<255, 254, 253>>,
      String.duplicate("x", 1_000_000),
      List.duplicate([], 10_000),
      deeply_nested,
      improper,
      huge_map,
      %JournalAsh.TestInspectBomb{value: "must-not-inspect"},
      self(),
      make_ref(),
      fn -> :ok end
    ]

    Enum.each(values, fn value ->
      assert {:ok, envelope} =
               Envelope.from_logger(
                 %{
                   level: :warning,
                   msg: {:report, value},
                   meta: %{
                     event: "test.adversarial",
                     arbitrary: value,
                     nested_report: {~c"authorization", value}
                   }
                 },
                 capture_reports: true,
                 metadata_keys: :all,
                 limits: Limits.hard()
               )

      assert_bounded(envelope)

      assert {:ok, %Entry{}} =
               Entry.from_observation(envelope, %Decision{
                 retention: :retain,
                 projections: [:standard_log]
               })
    end)
  end

  test "hard-limit redaction and struct normalization remain valid Ash entries" do
    redacted = Map.new(1..64, &{"password_#{&1}", "secret-#{&1}"})
    large_struct = struct(LargeStruct, Map.new(1..40, &{String.to_atom("field_#{&1}"), &1}))

    Enum.each([redacted, %{"large_struct" => large_struct}], fn metadata ->
      assert {:ok, envelope} =
               Envelope.from_logger(
                 %{level: :info, msg: {:string, "bounded"}, meta: metadata},
                 capture_reports: true,
                 metadata_keys: :all,
                 limits: Limits.hard()
               )

      assert_bounded(envelope)

      assert {:ok, %Entry{}} =
               Entry.from_observation(envelope, %Decision{
                 retention: :retain,
                 projections: [:standard_log]
               })
    end)
  end

  defp assert_bounded(envelope) do
    limits = Limits.hard()

    assert is_binary(envelope.message)
    assert String.valid?(envelope.message)
    assert byte_size(envelope.message) <= limits.max_message_bytes
    assert map_size(envelope.metadata) <= limits.max_metadata_entries
    assert canonical_map?(envelope.metadata, 1, limits)
    assert node_count_pairs(envelope.metadata) <= limits.max_total_nodes

    assert byte_size(envelope.message) + retained_binary_bytes(envelope.metadata) <=
             limits.max_total_bytes
  end

  defp canonical_map?(map, depth, limits) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      is_binary(key) and String.valid?(key) and
        canonical_value?(value, depth, limits)
    end)
  end

  defp canonical_value?(_value, depth, limits) when depth > limits.max_depth, do: false
  defp canonical_value?(nil, _depth, _limits), do: true
  defp canonical_value?(value, _depth, _limits) when is_boolean(value), do: true

  defp canonical_value?(value, _depth, _limits)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: true

  defp canonical_value?(value, _depth, _limits) when is_float(value),
    do: value == value and abs(value) <= 1.7976931348623157e308

  defp canonical_value?(value, _depth, _limits) when is_binary(value),
    do: String.valid?(value)

  defp canonical_value?(value, depth, limits) when is_map(value),
    do:
      map_size(value) <= limits.max_collection_items and
        canonical_map?(value, depth + 1, limits)

  defp canonical_value?(value, depth, limits) when is_list(value),
    do:
      length(value) <= limits.max_collection_items and
        Enum.all?(value, &canonical_value?(&1, depth + 1, limits))

  defp canonical_value?(_value, _depth, _limits), do: false

  defp node_count_pairs(map) do
    Enum.reduce(map, 0, fn {_key, value}, total -> total + 1 + node_count(value) end)
  end

  defp node_count(value) when is_map(value), do: 1 + node_count_pairs(value)

  defp node_count(value) when is_list(value),
    do: 1 + Enum.reduce(value, 0, &(&2 + node_count(&1)))

  defp node_count(_value), do: 1

  defp retained_binary_bytes(value) when is_binary(value), do: byte_size(value)

  defp retained_binary_bytes(value) when is_map(value) do
    Enum.reduce(value, 0, fn {key, nested}, total ->
      total + byte_size(key) + retained_binary_bytes(nested)
    end)
  end

  defp retained_binary_bytes(value) when is_list(value),
    do: Enum.reduce(value, 0, &(&2 + retained_binary_bytes(&1)))

  defp retained_binary_bytes(_value), do: 0
end

defmodule JournalAsh.SanitizerTest do
  use ExUnit.Case, async: true

  alias JournalAsh.{Envelope, Limits, Sanitizer}

  test "keyword secrets are redacted and oversized integers are replaced" do
    limits = Limits.new([])

    assert [%{"password" => "[REDACTED]"}] =
             Sanitizer.value([password: "do-not-retain"], limits)

    assert "[INTEGER_OUT_OF_RANGE]" = Sanitizer.value(Bitwise.bsl(1, 1_000_000), limits)
  end

  test "common API-key variants and bounded Erlang charlist keys are redacted" do
    limits = Limits.new([])

    assert %{
             "api_key" => "[REDACTED]",
             "passwd" => "[REDACTED]"
           } =
             Sanitizer.metadata(
               %{"api_key" => "API-SECRET", "passwd" => "PASSWORD-SECRET"},
               :all,
               limits
             )

    assert %{"authorization" => "[REDACTED]"} =
             Sanitizer.value({~c"authorization", ~c"Bearer CHARLIST-SECRET"}, limits)

    assert %{"api-key" => "[REDACTED]"} =
             Sanitizer.metadata(%{~c"api-key" => "MAP-SECRET"}, :all, limits)

    assert %{"passphrase" => "[REDACTED]", "private-key" => "[REDACTED]"} =
             Sanitizer.metadata(
               %{"passphrase" => "PASS-SECRET", "private-key" => "PEM-SECRET"},
               :all,
               limits
             )

    assert %{
             "accessKey" => "[REDACTED]",
             "apiKey" => "[REDACTED]",
             "privateKey" => "[REDACTED]"
           } =
             Sanitizer.metadata(
               %{"accessKey" => "A", "apiKey" => "K", "privateKey" => "P"},
               :all,
               limits
             )
  end

  test "malformed oversized UTF-8 is truncated in one bounded pass and detached" do
    input = String.duplicate("a", 4_096) <> :binary.copy(<<255>>, 100_000)
    output = Sanitizer.text(input, 8_192)

    assert output == String.duplicate("a", 4_096) <> "..."
    assert String.valid?(output)
    assert :binary.referenced_byte_size(output) == byte_size(output)
  end

  test "accepted subbinaries are detached from large Logger-owned binaries" do
    message_parent = String.duplicate("m", 1_000_000)
    key_parent = String.duplicate("k", 1_000_000)
    value_parent = String.duplicate("v", 1_000_000)
    event_parent = String.duplicate("e", 1_000_000)

    message = binary_part(message_parent, 100, 100)
    key = binary_part(key_parent, 100, 100)
    value = binary_part(value_parent, 100, 100)
    event = binary_part(event_parent, 100, 100)

    assert :binary.referenced_byte_size(message) > byte_size(message)
    assert :binary.referenced_byte_size(key) > byte_size(key)
    assert :binary.referenced_byte_size(value) > byte_size(value)
    assert :binary.referenced_byte_size(event) > byte_size(event)

    detached_message = Sanitizer.text(message, 8_192)
    detached_chardata = Sanitizer.text([message], 8_192)

    assert :binary.referenced_byte_size(detached_message) == byte_size(detached_message)
    assert :binary.referenced_byte_size(detached_chardata) == byte_size(detached_chardata)

    assert {:ok, envelope} =
             Envelope.from_logger(
               %{
                 level: :info,
                 msg: {:string, message},
                 meta: %{key => value, event: event}
               },
               metadata_keys: :all
             )

    assert :binary.referenced_byte_size(envelope.message) == byte_size(envelope.message)
    assert :binary.referenced_byte_size(envelope.event) == byte_size(envelope.event)

    {detached_key, detached_value} =
      Enum.find(envelope.metadata, fn {metadata_key, _value} -> metadata_key == key end)

    assert :binary.referenced_byte_size(detached_key) == byte_size(detached_key)
    assert :binary.referenced_byte_size(detached_value) == byte_size(detached_value)
  end

  test "producer policy and internal routing keys never enter metadata" do
    limits = Limits.new([])

    sanitized =
      Sanitizer.metadata(
        %{
          "JOURNAL_ASH_PRIVATE" => "private",
          "Retention" => :forever,
          journal_ash_decision: %{owner_token: "private"},
          journal_retention: :forever,
          safe: "kept"
        },
        :all,
        limits
      )

    assert sanitized == %{"safe" => "kept"}
  end

  test "oversized integer metadata keys never stringify on the caller path" do
    huge_key = Bitwise.bsl(1, 1_000_000)

    sanitized = Sanitizer.metadata(%{huge_key => "value"}, :all, Limits.new([]))

    assert sanitized == %{"[INTEGER_KEY_OUT_OF_RANGE]" => "value"}
  end

  test "overlong sensitive-looking top-level keys are rejected before classification" do
    overlong_key = String.duplicate("a", 5_000) <> "_password"

    sanitized =
      Sanitizer.metadata(
        %{overlong_key => "TOP-SECRET", "safe" => "kept"},
        :all,
        Limits.new([])
      )

    assert sanitized == %{"safe" => "kept"}
    refute inspect(sanitized) =~ "TOP-SECRET"
  end

  test "nested overlong and invalid keys are rejected before their values are retained" do
    overlong_key = String.duplicate("a", 5_000) <> "_token"
    invalid_key = <<255>>

    sanitized =
      Sanitizer.metadata(
        %{
          "nested" => %{
            overlong_key => "NESTED-SECRET",
            invalid_key => "INVALID-KEY-SECRET",
            "safe" => "kept"
          }
        },
        :all,
        Limits.new([])
      )

    assert sanitized == %{"nested" => %{"safe" => "kept"}}
    refute inspect(sanitized) =~ "SECRET"
  end

  test "configured structs cannot bypass hard ceilings" do
    limits = %Limits{
      max_message_bytes: 1_000_000,
      max_metadata_entries: 1_000_000,
      max_collection_items: 1_000_000,
      max_depth: 1_000_000,
      max_total_nodes: 1_000_000,
      max_total_bytes: 1_000_000_000
    }

    assert %Limits{
             max_message_bytes: 8_192,
             max_metadata_entries: 64,
             max_collection_items: 32,
             max_depth: 6,
             max_total_nodes: 64,
             max_total_bytes: 32_768
           } = Limits.new(limits)
  end

  test "message and metadata share one bounded binary-byte budget" do
    assert {:ok, envelope} =
             Envelope.from_logger(
               %{
                 level: :info,
                 msg: {:string, String.duplicate("m", 100)},
                 meta: %{
                   event: "test.byte_budget",
                   one: String.duplicate("a", 100),
                   two: String.duplicate("b", 100),
                   three: String.duplicate("c", 100)
                 }
               },
               metadata_keys: :all,
               limits: [max_message_bytes: 64, max_total_bytes: 128]
             )

    assert byte_size(envelope.message) + binary_bytes(envelope.metadata) <= 128
  end

  defp binary_bytes(value) when is_binary(value), do: byte_size(value)

  defp binary_bytes(value) when is_map(value) do
    Enum.reduce(value, 0, fn {key, nested}, total ->
      total + binary_bytes(key) + binary_bytes(nested)
    end)
  end

  defp binary_bytes(value) when is_list(value),
    do: Enum.reduce(value, 0, &(&2 + binary_bytes(&1)))

  defp binary_bytes(_value), do: 0
end

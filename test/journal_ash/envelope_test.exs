defmodule JournalAsh.EnvelopeTest do
  use ExUnit.Case, async: true

  alias JournalAsh.Envelope

  test "normalizes a Logger observation with a stable event name" do
    timestamp = System.system_time(:microsecond)

    assert {:ok, envelope} =
             Envelope.from_logger(%{
               level: :info,
               msg: {:string, "completed"},
               meta: %{
                 event: "workflow.task.completed",
                 request_id: "request-1",
                 time: timestamp
               }
             })

    assert envelope.kind == :observation
    assert envelope.source == :logger
    assert envelope.event == "workflow.task.completed"
    assert envelope.message == "completed"
    assert envelope.metadata["request_id"] == "request-1"
    assert DateTime.to_unix(envelope.observed_at, :microsecond) == timestamp
  end

  test "falls back for missing or unsafe event names" do
    assert {:ok, envelope} =
             Envelope.from_logger(%{
               level: :warning,
               msg: {:string, "hello"},
               meta: %{event: "NOT A SAFE EVENT"}
             })

    assert envelope.event == "logger.unstructured"
  end

  test "bounds messages and collections, redacts sensitive keys, and never inspects values" do
    assert {:ok, envelope} =
             Envelope.from_logger(
               %{
                 level: :info,
                 msg: {:string, String.duplicate("a", 100)},
                 meta: %{
                   event: "privacy.checked",
                   password: "do-not-store",
                   retention: :transient,
                   safe: %{
                     token: "do-not-store",
                     nested: %JournalAsh.TestInspectBomb{value: "safe"},
                     list: Enum.to_list(1..20)
                   }
                 }
               },
               limits: [max_message_bytes: 16, max_collection_items: 2, max_depth: 3],
               metadata_keys: :all
             )

    assert byte_size(envelope.message) <= 16
    assert envelope.metadata["password"] == "[REDACTED]"
    refute Map.has_key?(envelope.metadata, "retention")
    assert envelope.metadata["safe"]["token"] == "[REDACTED]"
    assert length(envelope.metadata["safe"]["list"]) == 2
  end

  test "report bodies are omitted unless the journal configuration permits them" do
    event = %{
      level: :error,
      msg: {:report, %{reason: "private detail", access_token: "secret"}},
      meta: %{event: "worker.failed"}
    }

    assert {:ok, omitted} = Envelope.from_logger(event)
    refute Map.has_key?(omitted.metadata, "report")

    assert {:ok, captured} = Envelope.from_logger(event, capture_reports: true)
    assert captured.metadata["report"]["access_token"] == "[REDACTED]"
  end

  test "source paths are not retained by the default metadata allowlist" do
    assert {:ok, envelope} =
             Envelope.from_logger(%{
               level: :info,
               msg: {:string, "hello"},
               meta: %{event: "privacy.source_path", file: "/private/work/client/lib/example.ex"}
             })

    refute Map.has_key?(envelope.metadata, "file")
  end

  test "rejects malformed logger events without raising" do
    assert {:error, :invalid_logger_event} = Envelope.from_logger(%{msg: :missing_level})
    assert {:error, :invalid_logger_event} = Envelope.from_logger(:not_an_event)
  end

  test "does not retain caller-owned DateTime metadata" do
    huge = String.duplicate("timezone", 100_000)
    forged = %{DateTime.utc_now() | time_zone: huge, zone_abbr: huge}

    assert {:ok, envelope} =
             Envelope.from_logger(%{
               level: :info,
               msg: {:string, "hello"},
               meta: %{event: "test.time", time: forged}
             })

    assert envelope.observed_at.time_zone == "Etc/UTC"
    assert envelope.observed_at.zone_abbr == "UTC"
  end
end

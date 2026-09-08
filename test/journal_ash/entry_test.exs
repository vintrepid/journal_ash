defmodule JournalAsh.EntryTest do
  use ExUnit.Case, async: true

  alias JournalAsh.{CommittedFact, Decision, Entry, Envelope}

  test "creates an Ash observation entry from the bounded envelope" do
    envelope = observation()
    decision = %Decision{retention: :retain, projections: [:standard_log]}

    assert {:ok, %Entry{} = entry} = Entry.from_observation(envelope, decision)
    assert entry.id == envelope.id
    assert String.at(entry.id, 14) == "7"
    assert entry.kind == :observation
    assert entry.decision["retention"] == "retain"
  end

  test "preserves canonical Logger message bytes without trimming" do
    envelope = %{observation() | message: "  observed  "}

    assert {:ok, %Entry{message: "  observed  "}} =
             Entry.from_observation(envelope, %Decision{
               retention: :retain,
               projections: [:standard_log]
             })
  end

  test "the Ash action rejects invalid events, levels, and oversized messages" do
    assert {:error, event_error} = record_observation(%{event: "INVALID EVENT"})
    assert Exception.message(event_error) =~ "event"

    assert {:error, level_error} = record_observation(%{level: :anything})
    assert Exception.message(level_error) =~ "level"

    assert {:error, message_error} =
             record_observation(%{message: String.duplicate("m", 8_193)})

    assert Exception.message(message_error) =~ "message"
  end

  test "the Ash action rejects unsanitized or structurally unbounded metadata" do
    assert {:error, secret_error} =
             record_observation(%{metadata: %{"password" => "CLEAR-TEXT-SECRET"}})

    assert Exception.message(secret_error) =~ "canonical, sanitized journal metadata"
    refute Exception.message(secret_error) =~ "CLEAR-TEXT-SECRET"

    assert {:error, budget_error} =
             record_observation(%{
               message: String.duplicate("m", 8_192),
               metadata: %{
                 "one" => String.duplicate("1", 8_000),
                 "two" => String.duplicate("2", 8_000),
                 "three" => String.duplicate("3", 8_000),
                 "four" => String.duplicate("4", 1_000)
               }
             })

    assert Exception.message(budget_error) =~ "metadata"
  end

  test "the Ash action accepts only the exact canonical decision shape" do
    invalid_decisions = [
      %{"retention" => "anything"},
      %{"retention" => "retain", "projections" => ["unknown"], "reason" => nil},
      %{
        "retention" => "retain",
        "projections" => ["telemetry", "telemetry"],
        "reason" => nil
      },
      %{
        "retention" => "retain",
        "projections" => [],
        "reason" => nil,
        "producer_override" => true
      }
    ]

    Enum.each(invalid_decisions, fn decision ->
      assert {:error, error} = record_observation(%{decision: decision})
      assert Exception.message(error) =~ "canonical journal decision"
    end)
  end

  test "direct envelope construction cannot bypass canonical action validation" do
    envelope = %{
      observation()
      | metadata: %{"api_token" => "CLEAR-TEXT-SECRET"},
        event: "INVALID"
    }

    assert {:error, error} =
             Entry.from_observation(envelope, %Decision{
               retention: :retain,
               projections: [:standard_log]
             })

    refute Exception.message(error) =~ "CLEAR-TEXT-SECRET"

    assert {:error, :invalid_decision} =
             Entry.from_observation(observation(), %Decision{
               retention: :retain,
               projections: [:standard_log, :standard_log]
             })
  end

  test "the Ash action detaches canonical binaries from caller-owned parents" do
    parent = String.duplicate("a", 10_000_000)
    fragment = binary_part(parent, 100, 100)

    assert :binary.referenced_byte_size(fragment) > byte_size(fragment)

    assert {:ok, entry} =
             record_observation(%{
               event: fragment,
               message: fragment,
               metadata: %{fragment => fragment},
               decision: %{
                 "retention" => "retain",
                 "projections" => ["standard_log"],
                 "reason" => fragment
               }
             })

    {metadata_key, metadata_value} = Enum.at(entry.metadata, 0)

    for value <- [
          entry.event,
          entry.message,
          metadata_key,
          metadata_value,
          entry.decision["reason"]
        ] do
      assert :binary.referenced_byte_size(value) == byte_size(value)
    end
  end

  test "committed facts require an explicit transaction identity and commit timestamp" do
    attributes = %{
      event: "workflow.task.completed",
      resource: "Example.Task",
      action: :complete,
      record_id: "task-1",
      transaction_id: "transaction-1",
      committed_at: DateTime.utc_now()
    }

    assert {:ok, %CommittedFact{} = fact} = CommittedFact.new(attributes)
    assert fact.transaction_id == "transaction-1"

    assert {:error, :invalid_committed_fact} =
             attributes |> Map.delete(:transaction_id) |> CommittedFact.new()
  end

  test "the alpha Ash resource exposes no update or destroy action" do
    actions = Ash.Resource.Info.actions(Entry)

    assert Enum.map(actions, & &1.name) == [:record_observation]
    refute Enum.any?(actions, &(&1.type in [:update, :destroy]))
  end

  defp observation do
    %Envelope{
      id: Ash.UUIDv7.generate(),
      kind: :observation,
      source: :logger,
      event: "test.observed",
      level: :info,
      message: "observed",
      metadata: %{},
      observed_at: DateTime.utc_now()
    }
  end

  defp record_observation(overrides) do
    attributes = %{
      id: Ash.UUIDv7.generate(),
      source: :logger,
      event: "test.observed",
      level: :info,
      message: "observed",
      metadata: %{},
      observed_at: DateTime.utc_now(),
      decision: %{
        "retention" => "retain",
        "projections" => ["standard_log"],
        "reason" => nil
      }
    }

    Entry
    |> Ash.Changeset.for_create(:record_observation, Map.merge(attributes, overrides))
    |> Ash.create()
  end
end

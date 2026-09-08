defmodule JournalAsh.DecisionTest do
  use ExUnit.Case, async: true

  alias JournalAsh.Decision

  defmodule MalformedPolicy do
    @behaviour JournalAsh.Policy

    @impl true
    def decide(_envelope, _options) do
      %Decision{retention: :garbage, projections: :not_a_list, reason: self()}
    end
  end

  test "accepts only journal-owned retention and known projections" do
    assert {:ok, decision} =
             Decision.new(retention: :retain, projections: [:standard_log, :telemetry])

    assert Decision.retain?(decision)
    assert Decision.project?(decision, :standard_log)

    assert {:error, :invalid_decision} = Decision.new(retention: :producer_choice)
    assert {:error, :invalid_decision} = Decision.new(projections: [:unknown_sink])
  end

  test "invalid policy decisions fail safe to retention and conventional output" do
    decision = JournalAsh.Policy.evaluate(observation(), MalformedPolicy)

    assert decision.retention == :retain
    assert decision.projections == [:standard_log]
    assert decision.reason == :policy_failure
  end

  test "bounded string policy reasons are retained" do
    assert {:ok, decision} = Decision.new(reason: "application-rule")
    assert Decision.to_map(decision)["reason"] == "application-rule"
  end

  test "rejects duplicate or unbounded projection lists in constant work" do
    assert {:error, :invalid_decision} =
             Decision.new(projections: [:standard_log, :standard_log])

    assert {:error, :invalid_decision} =
             Decision.new(projections: List.duplicate(:standard_log, 100_000))
  end

  test "detaches bounded string reasons from caller-owned binaries" do
    parent = String.duplicate("r", 1_000_000)
    reason = binary_part(parent, 100, 100)

    assert :binary.referenced_byte_size(reason) > byte_size(reason)
    assert {:ok, decision} = Decision.new(reason: reason)
    assert :binary.referenced_byte_size(decision.reason) == byte_size(decision.reason)
  end

  defp observation do
    %JournalAsh.Envelope{
      id: Ash.UUIDv7.generate(),
      kind: :observation,
      source: :logger,
      event: "test.policy",
      level: :info,
      message: "test",
      metadata: %{},
      observed_at: DateTime.utc_now()
    }
  end
end

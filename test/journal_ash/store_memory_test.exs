defmodule JournalAsh.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias JournalAsh.{Decision, Entry, Envelope}
  alias JournalAsh.Store.Memory

  test "is idempotent by entry ID and retains a bounded newest window" do
    name = start_supervised!({Memory, name: nil, max_entries: 2})
    options = [name: name]

    first = entry("first")
    second = entry("second")
    third = entry("third")

    assert :ok = Memory.append(first, options)
    assert :ok = Memory.append(first, options)
    assert :ok = Memory.append(second, options)
    assert :ok = Memory.append(third, options)

    assert Enum.map(Memory.entries(options), & &1.message) == ["second", "third"]
    assert Memory.health(options).durability == :volatile
  end

  test "host configuration cannot raise volatile retention above its hard ceiling" do
    name = start_supervised!({Memory, name: nil, max_entries: 1_000_000})
    assert Memory.health(name: name).capacity == 4_096
  end

  defp entry(message) do
    envelope = %Envelope{
      id: Ash.UUIDv7.generate(),
      kind: :observation,
      source: :logger,
      event: "test.memory",
      level: :info,
      message: message,
      metadata: %{},
      observed_at: DateTime.utc_now()
    }

    {:ok, entry} =
      Entry.from_observation(
        envelope,
        %Decision{retention: :retain, projections: [:standard_log]}
      )

    entry
  end
end

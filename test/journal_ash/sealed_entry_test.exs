defmodule JournalAsh.SealedEntryTest do
  use ExUnit.Case, async: false

  alias JournalAsh.{Decision, Entry, Envelope, SealedEntry}

  @key :binary.copy(<<17>>, 32)
  @wrong_key :binary.copy(<<23>>, 32)
  @cipher_tag "JOURNAL.AES.GCM.V1"

  setup do
    start_supervised!(
      {JournalAsh.TestVault,
       ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: @cipher_tag, key: @key}]}
    )

    start_supervised!(
      {JournalAsh.TestWrongVault,
       ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: @cipher_tag, key: @wrong_key}]}
    )

    :ok
  end

  test "seals every entry field except its storage identity and round trips through JSON" do
    entry = private_entry()

    assert {:ok, sealed} = SealedEntry.seal(entry, JournalAsh.TestVault)

    persisted = SealedEntry.to_map(sealed)
    encoded = Jason.encode!(persisted)

    assert persisted == Jason.decode!(encoded)
    assert persisted["format"] == SealedEntry.format()
    assert persisted["version"] == SealedEntry.version()
    assert persisted["entry_id"] == entry.id

    for private_value <- [
          entry.event,
          entry.message,
          entry.metadata["request_id"],
          entry.decision["reason"],
          DateTime.to_iso8601(entry.observed_at)
        ] do
      refute encoded =~ private_value
    end

    assert {:ok, opened} = SealedEntry.open(Jason.decode!(encoded), JournalAsh.TestVault)

    for field <- [
          :id,
          :kind,
          :source,
          :event,
          :level,
          :message,
          :metadata,
          :observed_at,
          :decision
        ] do
      assert Map.fetch!(opened, field) == Map.fetch!(entry, field)
    end
  end

  test "uses randomized authenticated encryption while preserving the idempotency key" do
    entry = private_entry()

    assert {:ok, first} = SealedEntry.seal(entry, JournalAsh.TestVault)
    assert {:ok, second} = SealedEntry.seal(entry, JournalAsh.TestVault)

    assert first.entry_id == second.entry_id
    refute first.ciphertext == second.ciphertext
    assert {:ok, %{id: id}} = SealedEntry.open(first, JournalAsh.TestVault)
    assert id == entry.id
    assert {:ok, %{id: ^id}} = SealedEntry.open(second, JournalAsh.TestVault)
  end

  test "fails closed for a wrong key, tampering, and an outer identity mismatch" do
    entry = private_entry()
    assert {:ok, sealed} = SealedEntry.seal(entry, JournalAsh.TestVault)

    assert {:error, :decryption_failed} =
             SealedEntry.open(sealed, JournalAsh.TestWrongVault)

    ciphertext = Base.url_decode64!(sealed.ciphertext, padding: false)
    last_index = byte_size(ciphertext) - 1
    prefix = binary_part(ciphertext, 0, last_index)
    last = :binary.last(ciphertext)

    tampered = %{
      sealed
      | ciphertext: Base.url_encode64(prefix <> <<Bitwise.bxor(last, 1)>>, padding: false)
    }

    assert {:error, :decryption_failed} = SealedEntry.open(tampered, JournalAsh.TestVault)

    mismatched = %{sealed | entry_id: Ash.UUIDv7.generate()}
    assert {:error, :invalid_plaintext} = SealedEntry.open(mismatched, JournalAsh.TestVault)
  end

  test "rejects unsupported, malformed, and oversized storage values before opening them" do
    entry = private_entry()
    assert {:ok, sealed} = SealedEntry.seal(entry, JournalAsh.TestVault)
    persisted = SealedEntry.to_map(sealed)

    assert {:error, :unsupported_format} =
             persisted
             |> Map.put("version", 2)
             |> SealedEntry.open(JournalAsh.TestVault)

    assert {:error, :unsupported_format} =
             persisted
             |> Map.put("version", 1.0)
             |> SealedEntry.open(JournalAsh.TestVault)

    assert {:error, :invalid_sealed_entry} =
             persisted
             |> Map.put("unexpected", true)
             |> SealedEntry.open(JournalAsh.TestVault)

    assert {:error, :invalid_ciphertext} =
             persisted
             |> Map.put("ciphertext", "not base64!")
             |> SealedEntry.open(JournalAsh.TestVault)

    assert {:error, :ciphertext_too_large} =
             persisted
             |> Map.put("ciphertext", String.duplicate("A", 400_000))
             |> SealedEntry.open(JournalAsh.TestVault)
  end

  test "revalidates forged entries before asking the vault to encrypt" do
    oversized = %{private_entry() | message: String.duplicate("private", 8_193)}
    wrong_kind = %{private_entry() | kind: :committed_fact}

    assert {:error, :invalid_entry} = SealedEntry.seal(oversized, JournalAsh.TestRaisingVault)
    assert {:error, :invalid_entry} = SealedEntry.seal(wrong_kind, JournalAsh.TestRaisingVault)
  end

  test "returns only opaque errors for unavailable or invalid vault behavior" do
    entry = private_entry()

    assert {:error, :invalid_vault} = SealedEntry.seal(entry, String)
    assert {:error, :encryption_failed} = SealedEntry.seal(entry, JournalAsh.TestInvalidVault)
    assert {:error, :encryption_failed} = SealedEntry.seal(entry, JournalAsh.TestRaisingVault)

    assert {:ok, sealed} = SealedEntry.seal(entry, JournalAsh.TestVault)

    assert {:error, :decryption_failed} =
             SealedEntry.open(sealed, JournalAsh.TestInvalidVault)

    assert {:error, :decryption_failed} =
             SealedEntry.open(sealed, JournalAsh.TestRaisingVault)
  end

  test "rejects authenticated plaintext with an unknown schema or excessive size" do
    entry = private_entry()

    unsupported_payload =
      Jason.encode!(%{
        "format" => "journal_ash.entry",
        "version" => 2,
        "entry" => %{}
      })

    assert {:error, :invalid_plaintext} =
             unsupported_payload
             |> seal_raw!(entry.id)
             |> SealedEntry.open(JournalAsh.TestVault)

    excessive_plaintext = String.duplicate("x", 262_145)

    assert {:error, :invalid_plaintext} =
             excessive_plaintext
             |> seal_raw!(entry.id)
             |> SealedEntry.open(JournalAsh.TestVault)
  end

  defp private_entry do
    envelope = %Envelope{
      id: Ash.UUIDv7.generate(),
      kind: :observation,
      source: :logger,
      event: "payroll.private.reviewed",
      level: :warning,
      message: "private journal payload 82e6db59-f645-45e3-bc87-febaaf75d53b",
      metadata: %{
        "request_id" => "private-request-c74b770c",
        "resource" => "Private.Resource"
      },
      observed_at: DateTime.utc_now()
    }

    decision = %Decision{
      retention: :retain,
      projections: [:standard_log],
      reason: "private-retention-policy"
    }

    {:ok, %Entry{} = entry} = Entry.from_observation(envelope, decision)
    entry
  end

  defp seal_raw!(plaintext, entry_id) do
    {:ok, ciphertext} = JournalAsh.TestVault.encrypt(plaintext)

    %{
      "format" => SealedEntry.format(),
      "version" => SealedEntry.version(),
      "entry_id" => entry_id,
      "ciphertext" => Base.url_encode64(ciphertext, padding: false)
    }
  end
end

defmodule JournalAsh.SealedEntry do
  @moduledoc """
  A versioned, JSON-safe encrypted representation of a journal entry.

  Store adapters can call `seal/2` with their host application's trusted
  `Cloak.Vault` module, persist `to_map/1`, and use `open/2` when an authorized
  reader needs the canonical `JournalAsh.Entry` again. JournalAsh never chooses
  or generates a key. The host owns vault configuration, supervision, key
  rotation, and access to decrypted values.

  Only `entry_id`, `format`, and `version` remain clear. The clear ID is a
  deliberate storage key that lets adapters make retries idempotent. Every
  other entry field is inside the ciphertext, including event, level,
  timestamp, decision, message, and metadata. The encrypted payload repeats the
  ID and format; `open/2` rejects mismatches after authenticated decryption.

  Use an authenticated Cloak cipher such as `Cloak.Ciphers.AES.GCM`. This
  module can validate Cloak's interface and returned shapes, but it cannot prove
  that a host-supplied cipher provides confidentiality or integrity.

  The default `JournalAsh.Store.Memory` does not use this codec and remains
  plaintext and volatile. Merely depending on Cloak does not encrypt a store.
  This is server-held-key encryption at rest: plaintext exists before sealing,
  and the service can decrypt while it holds the vault key. It is separate from
  sanitizer redaction and is not client-held-key end-to-end encryption.
  """

  alias JournalAsh.Entry

  @format "journal_ash.sealed_entry"
  @version 1
  @payload_format "journal_ash.entry"
  @payload_version 1

  # A canonical Logger entry contains at most 32 KiB of message and metadata,
  # but JSON escaping can expand a control-character-heavy string sixfold. The
  # codec keeps a separate hard ceiling so neither public calls nor corrupted
  # stored values can create unbounded encoding or decoding work.
  @maximum_plaintext_bytes 262_144
  @maximum_ciphertext_bytes 263_168
  @maximum_encoded_ciphertext_bytes div(@maximum_ciphertext_bytes + 2, 3) * 4

  @enforce_keys [:entry_id, :ciphertext]
  defstruct format: @format,
            version: @version,
            entry_id: nil,
            ciphertext: nil

  @type t :: %__MODULE__{
          format: String.t(),
          version: pos_integer(),
          entry_id: String.t(),
          ciphertext: String.t()
        }

  @type error ::
          :ciphertext_too_large
          | :decryption_failed
          | :encoding_failed
          | :encryption_failed
          | :entry_too_large
          | :invalid_ciphertext
          | :invalid_entry
          | :invalid_plaintext
          | :invalid_sealed_entry
          | :invalid_vault
          | :unsupported_format

  @doc "Returns the stable outer storage format name."
  @spec format() :: String.t()
  def format, do: @format

  @doc "Returns the current outer storage format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Validates and encrypts a complete canonical entry with a trusted host vault.

  The vault must already be configured and supervised. Encryption errors are
  deliberately opaque and never produce a plaintext fallback.
  """
  @spec seal(Entry.t(), module()) :: {:ok, t()} | {:error, error()}
  def seal(%Entry{} = entry, vault) when is_atom(vault) do
    with :ok <- validate_vault(vault),
         {:ok, entry} <- canonical_entry(entry),
         {:ok, plaintext} <- encode_entry(entry),
         :ok <- bounded_plaintext(plaintext, :entry_too_large),
         {:ok, ciphertext} <- encrypt(vault, plaintext),
         :ok <- bounded_ciphertext(ciphertext) do
      {:ok,
       %__MODULE__{
         entry_id: :binary.copy(entry.id),
         ciphertext: Base.url_encode64(ciphertext, padding: false)
       }}
    end
  end

  def seal(%Entry{}, _invalid_vault), do: {:error, :invalid_vault}
  def seal(_invalid_entry, _vault), do: {:error, :invalid_entry}

  @doc """
  Decrypts and revalidates a sealed entry with a trusted host vault.

  Maps must have exactly the keys emitted by `to_map/1`. Unsupported versions,
  malformed values, decryption failures, and invalid plaintext all fail closed.
  """
  @spec open(t() | map(), module()) :: {:ok, Entry.t()} | {:error, error()}
  def open(sealed, vault) when is_atom(vault) do
    with :ok <- validate_vault(vault),
         {:ok, sealed} <- from_map(sealed),
         {:ok, ciphertext} <- decode_ciphertext(sealed.ciphertext),
         {:ok, plaintext} <- decrypt(vault, ciphertext),
         :ok <- bounded_plaintext(plaintext, :invalid_plaintext),
         {:ok, payload} <- decode_json(plaintext),
         {:ok, attributes} <- decode_payload(payload, sealed.entry_id),
         {:ok, entry} <- create_decoded_entry(attributes),
         true <- entry.id == sealed.entry_id do
      {:ok, entry}
    else
      false -> {:error, :invalid_plaintext}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_plaintext}
    end
  end

  def open(_sealed, _invalid_vault), do: {:error, :invalid_vault}

  @doc "Returns the exact JSON-safe map intended for a ciphertext store."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = sealed) do
    %{
      "format" => sealed.format,
      "version" => sealed.version,
      "entry_id" => sealed.entry_id,
      "ciphertext" => sealed.ciphertext
    }
  end

  @doc "Validates an exact JSON-decoded sealed-entry map or struct."
  @spec from_map(t() | map()) :: {:ok, t()} | {:error, error()}
  def from_map(%__MODULE__{} = sealed), do: sealed |> to_map() |> from_map()

  def from_map(
        %{
          "format" => format,
          "version" => version,
          "entry_id" => entry_id,
          "ciphertext" => ciphertext
        } = map
      )
      when map_size(map) == 4 do
    cond do
      format !== @format or version !== @version ->
        {:error, :unsupported_format}

      not valid_entry_id?(entry_id) ->
        {:error, :invalid_sealed_entry}

      not is_binary(ciphertext) ->
        {:error, :invalid_sealed_entry}

      byte_size(ciphertext) > @maximum_encoded_ciphertext_bytes ->
        {:error, :ciphertext_too_large}

      not valid_encoded_ciphertext?(ciphertext) ->
        {:error, :invalid_ciphertext}

      true ->
        {:ok,
         %__MODULE__{
           entry_id: :binary.copy(entry_id),
           ciphertext: :binary.copy(ciphertext)
         }}
    end
  end

  def from_map(_invalid), do: {:error, :invalid_sealed_entry}

  defp canonical_entry(%Entry{kind: :observation} = entry) do
    create_entry(%{
      id: entry.id,
      source: entry.source,
      event: entry.event,
      level: entry.level,
      message: entry.message,
      metadata: entry.metadata,
      observed_at: entry.observed_at,
      decision: entry.decision
    })
  end

  defp canonical_entry(%Entry{}), do: {:error, :invalid_entry}

  defp create_entry(attributes) do
    Entry
    |> Ash.Changeset.for_create(:record_observation, attributes)
    |> Ash.create()
    |> case do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      {:error, _error} -> {:error, :invalid_entry}
      _invalid -> {:error, :invalid_entry}
    end
  rescue
    _error -> {:error, :invalid_entry}
  catch
    _kind, _reason -> {:error, :invalid_entry}
  end

  defp create_decoded_entry(attributes) do
    case create_entry(attributes) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      {:error, _reason} -> {:error, :invalid_plaintext}
    end
  end

  defp encode_entry(%Entry{} = entry) do
    payload = %{
      "format" => @payload_format,
      "version" => @payload_version,
      "entry" => %{
        "id" => entry.id,
        "kind" => "observation",
        "source" => "logger",
        "event" => entry.event,
        "level" => Atom.to_string(entry.level),
        "message" => entry.message,
        "metadata" => entry.metadata,
        "observed_at" => DateTime.to_iso8601(entry.observed_at),
        "decision" => entry.decision
      }
    }

    case Jason.encode(payload) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _invalid -> {:error, :encoding_failed}
    end
  rescue
    _error -> {:error, :encoding_failed}
  catch
    _kind, _reason -> {:error, :encoding_failed}
  end

  defp decode_payload(
         %{
           "format" => @payload_format,
           "version" => @payload_version,
           "entry" =>
             %{
               "id" => entry_id,
               "kind" => "observation",
               "source" => "logger",
               "event" => event,
               "level" => level,
               "message" => message,
               "metadata" => metadata,
               "observed_at" => observed_at,
               "decision" => decision
             } = entry
         } = payload,
         outer_entry_id
       )
       when map_size(payload) == 3 and map_size(entry) == 9 and entry_id == outer_entry_id do
    with {:ok, level} <- decode_level(level),
         {:ok, observed_at} <- decode_datetime(observed_at) do
      {:ok,
       %{
         id: entry_id,
         source: :logger,
         event: event,
         level: level,
         message: message,
         metadata: metadata,
         observed_at: observed_at,
         decision: decision
       }}
    end
  end

  defp decode_payload(_payload, _entry_id), do: {:error, :invalid_plaintext}

  defp decode_level("debug"), do: {:ok, :debug}
  defp decode_level("info"), do: {:ok, :info}
  defp decode_level("notice"), do: {:ok, :notice}
  defp decode_level("warning"), do: {:ok, :warning}
  defp decode_level("error"), do: {:ok, :error}
  defp decode_level("critical"), do: {:ok, :critical}
  defp decode_level("alert"), do: {:ok, :alert}
  defp decode_level("emergency"), do: {:ok, :emergency}
  defp decode_level(_invalid), do: {:error, :invalid_plaintext}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :invalid_plaintext}
    end
  end

  defp decode_datetime(_invalid), do: {:error, :invalid_plaintext}

  defp decode_json(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _invalid -> {:error, :invalid_plaintext}
    end
  rescue
    _error -> {:error, :invalid_plaintext}
  catch
    _kind, _reason -> {:error, :invalid_plaintext}
  end

  defp bounded_plaintext(plaintext, _error)
       when is_binary(plaintext) and byte_size(plaintext) <= @maximum_plaintext_bytes,
       do: :ok

  defp bounded_plaintext(_plaintext, error), do: {:error, error}

  defp bounded_ciphertext(ciphertext)
       when is_binary(ciphertext) and byte_size(ciphertext) <= @maximum_ciphertext_bytes,
       do: :ok

  defp bounded_ciphertext(_ciphertext), do: {:error, :ciphertext_too_large}

  defp decode_ciphertext(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, ciphertext} when byte_size(ciphertext) <= @maximum_ciphertext_bytes ->
        {:ok, ciphertext}

      {:ok, _oversized} ->
        {:error, :ciphertext_too_large}

      :error ->
        {:error, :invalid_ciphertext}
    end
  rescue
    _error -> {:error, :invalid_ciphertext}
  end

  defp valid_encoded_ciphertext?(encoded),
    do: match?({:ok, _ciphertext}, decode_ciphertext(encoded))

  defp encrypt(vault, plaintext) do
    case vault.encrypt(plaintext) do
      {:ok, ciphertext} when is_binary(ciphertext) -> {:ok, ciphertext}
      _failure -> {:error, :encryption_failed}
    end
  rescue
    _error -> {:error, :encryption_failed}
  catch
    _kind, _reason -> {:error, :encryption_failed}
  end

  defp decrypt(vault, ciphertext) do
    case vault.decrypt(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _failure -> {:error, :decryption_failed}
    end
  rescue
    _error -> {:error, :decryption_failed}
  catch
    _kind, _reason -> {:error, :decryption_failed}
  end

  defp validate_vault(vault) do
    if Code.ensure_loaded?(vault) and function_exported?(vault, :encrypt, 1) and
         function_exported?(vault, :decrypt, 1) do
      :ok
    else
      {:error, :invalid_vault}
    end
  rescue
    _error -> {:error, :invalid_vault}
  end

  defp valid_entry_id?(entry_id) when is_binary(entry_id) and byte_size(entry_id) == 36 do
    match?(<<_::48, 7::4, _::12, 0b10::2, _::62>>, Ash.UUIDv7.decode(entry_id))
  rescue
    _error -> false
  end

  defp valid_entry_id?(_invalid), do: false
end

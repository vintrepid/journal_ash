defmodule JournalAsh.CommittedFact do
  @moduledoc """
  Typed boundary for a fact linked to a committed Ash transaction.

  JournalAsh 0.1 does not ingest this value. A future Ash resource change must
  write it inside the same data-layer transaction as the source mutation, and
  the enclosing transaction may commit only when both writes succeed. Keeping
  the type separate prevents Logger observations from being presented as
  authoritative business history.
  """

  @maximum_name_bytes 160
  @maximum_identity_bytes 255
  @name_pattern ~r/^[A-Za-z][A-Za-z0-9_.:-]*$/

  @enforce_keys [
    :id,
    :event,
    :resource,
    :action,
    :record_id,
    :transaction_id,
    :committed_at
  ]
  defstruct [
    :id,
    :event,
    :resource,
    :action,
    :record_id,
    :transaction_id,
    :committed_at,
    changes: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          event: String.t(),
          resource: String.t(),
          action: String.t(),
          record_id: String.t(),
          transaction_id: String.t(),
          committed_at: DateTime.t(),
          changes: map(),
          metadata: map()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_committed_fact}
  def new(attributes) when is_list(attributes), do: attributes |> Map.new() |> new()

  def new(attributes) when is_map(attributes) do
    with {:ok, event} <- name(Map.get(attributes, :event)),
         {:ok, resource} <- name(Map.get(attributes, :resource)),
         {:ok, action} <- name(Map.get(attributes, :action)),
         {:ok, record_id} <- identity(Map.get(attributes, :record_id)),
         {:ok, transaction_id} <- identity(Map.get(attributes, :transaction_id)),
         %DateTime{} = committed_at <- Map.get(attributes, :committed_at),
         changes when is_map(changes) <- Map.get(attributes, :changes, %{}),
         metadata when is_map(metadata) <- Map.get(attributes, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: Ash.UUIDv7.generate(),
         event: event,
         resource: resource,
         action: action,
         record_id: record_id,
         transaction_id: transaction_id,
         committed_at: committed_at,
         changes: changes,
         metadata: metadata
       }}
    else
      _invalid -> {:error, :invalid_committed_fact}
    end
  rescue
    _error -> {:error, :invalid_committed_fact}
  end

  def new(_attributes), do: {:error, :invalid_committed_fact}

  defp name(value) when is_atom(value), do: value |> Atom.to_string() |> name()

  defp name(value) when is_binary(value) do
    if byte_size(value) in 1..@maximum_name_bytes and Regex.match?(@name_pattern, value) do
      {:ok, value}
    else
      {:error, :invalid_name}
    end
  end

  defp name(_value), do: {:error, :invalid_name}

  defp identity(value) when is_integer(value), do: value |> Integer.to_string() |> identity()

  defp identity(value) when is_binary(value) do
    if byte_size(value) in 1..@maximum_identity_bytes and String.valid?(value) do
      {:ok, value}
    else
      {:error, :invalid_identity}
    end
  end

  defp identity(_value), do: {:error, :invalid_identity}
end

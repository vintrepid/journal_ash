defmodule JournalAsh.Decision do
  @moduledoc """
  A journal-owned retention and projection decision.

  Producers do not construct decisions. JournalAsh evaluates its configured
  `JournalAsh.Policy` before attempting to admit an event to the bounded queue.
  """

  @retentions [:retain, :transient]
  @projections [:standard_log, :telemetry]

  @enforce_keys [:retention, :projections]
  defstruct retention: :retain, projections: [:standard_log], reason: nil

  @type retention :: :retain | :transient
  @type projection :: :standard_log | :telemetry

  @type t :: %__MODULE__{
          retention: retention(),
          projections: [projection()],
          reason: atom() | String.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_decision}
  def new(options \\ []) when is_list(options) do
    retention = Keyword.get(options, :retention, :retain)
    projections = Keyword.get(options, :projections, [:standard_log])
    reason = Keyword.get(options, :reason)

    if retention in @retentions and valid_projections?(projections) and valid_reason?(reason) do
      {:ok,
       %__MODULE__{
         retention: retention,
         projections: projections,
         reason: detach_reason(reason)
       }}
    else
      {:error, :invalid_decision}
    end
  rescue
    _error -> {:error, :invalid_decision}
  end

  @spec retain?(t()) :: boolean()
  def retain?(%__MODULE__{retention: :retain}), do: true
  def retain?(%__MODULE__{}), do: false

  @spec project?(t(), projection()) :: boolean()
  def project?(%__MODULE__{projections: projections}, projection),
    do: projection in projections

  @doc false
  @spec validate(t()) :: {:ok, t()} | {:error, :invalid_decision}
  def validate(%__MODULE__{} = decision) do
    new(
      retention: decision.retention,
      projections: decision.projections,
      reason: decision.reason
    )
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    %{
      "retention" => Atom.to_string(decision.retention),
      "projections" => Enum.map(decision.projections, &Atom.to_string/1),
      "reason" => encode_reason(decision.reason)
    }
  end

  defp valid_projections?([]), do: true
  defp valid_projections?([projection]), do: projection in @projections

  defp valid_projections?([first, second]),
    do: first in @projections and second in @projections and first != second

  defp valid_projections?(_projections), do: false

  defp valid_reason?(nil), do: true

  defp valid_reason?(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> valid_reason?()

  defp valid_reason?(reason) when is_binary(reason),
    do: byte_size(reason) <= 160 and String.valid?(reason)

  defp valid_reason?(_reason), do: false

  defp encode_reason(nil), do: nil
  defp encode_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp encode_reason(reason) when is_binary(reason), do: reason

  defp detach_reason(reason) when is_binary(reason), do: :binary.copy(reason)
  defp detach_reason(reason), do: reason
end

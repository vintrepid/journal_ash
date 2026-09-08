defmodule JournalAsh.Policy do
  @moduledoc """
  Behaviour for the journal's central output policy.

  Policy is evaluated by JournalAsh, never by event producers. Implementations
  must be deterministic, bounded, and side-effect free because they run in the
  process emitting the Logger event.
  """

  alias JournalAsh.{Decision, Envelope}

  @type options :: keyword() | map()

  @callback decide(Envelope.t(), options()) :: Decision.t() | {:ok, Decision.t()}

  @spec evaluate(Envelope.t(), module() | {module(), options()}) :: Decision.t()
  def evaluate(%Envelope{} = envelope, policy) do
    {module, options} = normalize(policy)

    result =
      case module.decide(envelope, options) do
        %Decision{} = decision -> Decision.validate(decision)
        {:ok, %Decision{} = decision} -> Decision.validate(decision)
        _invalid -> {:error, :invalid_decision}
      end

    case result do
      {:ok, decision} -> decision
      {:error, :invalid_decision} -> fallback()
    end
  rescue
    _error -> fallback()
  catch
    _kind, _reason -> fallback()
  end

  @spec fallback() :: Decision.t()
  def fallback do
    %Decision{
      retention: :retain,
      projections: [:standard_log],
      reason: :policy_failure
    }
  end

  defp normalize({module, options}) when is_atom(module), do: {module, options}
  defp normalize(module) when is_atom(module), do: {module, []}
  defp normalize(_invalid), do: {JournalAsh.Policy.Default, []}
end

defmodule JournalAsh do
  @moduledoc """
  A journal-owned observation pipeline for Ash applications.

  Application code keeps using Elixir's `Logger` API. JournalAsh installs an
  OTP Logger primary filter, accepts events into a strictly bounded queue,
  applies one central policy, and sends retained observations to a configured
  store.

  JournalAsh is not event sourcing: current Ash resources remain authoritative
  and no API rebuilds state by replaying journal entries.
  """

  alias JournalAsh.{Intake, LoggerIntegration, RuntimeConfiguration}

  @doc "Returns bounded intake, store, and Logger-filter health."
  @spec health() :: map()
  def health do
    with {:ok, configuration} <- RuntimeConfiguration.fetch() do
      active_health(configuration)
    else
      :error ->
        %{
          status: :unavailable,
          reason: :application_not_running,
          logger: %{primary_filter: :unavailable, primary_filter_order: :unavailable}
        }
    end
  end

  defp active_health(configuration) do
    intake = Intake.health(configuration.intake)
    logger = LoggerIntegration.health(configuration)

    logger_ready? =
      match?(
        %{primary_filter: :installed, primary_filter_order: :last, primary_filter_default: :log},
        logger
      ) or
        match?(%{primary_filter: :disabled, primary_filter_order: :disabled}, logger)

    status = if intake.status == :ready and not logger_ready?, do: :degraded, else: intake.status

    intake
    |> Map.put(:status, status)
    |> Map.put(:logger, logger)
  end

  @doc "Drains intake to empty, then flushes the store, or returns on timeout."
  @spec flush(pos_integer()) :: :ok | {:error, term()}
  def flush(timeout \\ 5_000) do
    with {:ok, configuration} <- RuntimeConfiguration.fetch() do
      Intake.flush(configuration.intake, timeout)
    else
      :error -> {:error, :application_not_running}
    end
  end
end

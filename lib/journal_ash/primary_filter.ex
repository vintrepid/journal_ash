defmodule JournalAsh.PrimaryFilter do
  @moduledoc false

  alias JournalAsh.{Decision, Emergency, Envelope, Intake, Internal, Policy}

  @spec filter(:logger.log_event(), term()) :: :logger.log_event() | :stop | :ignore
  def filter(log_event, {:journal_ash_runtime, runtime_key}) do
    case :persistent_term.get(runtime_key, :inactive) do
      %{
        owner_pid: owner_pid,
        owner_token: owner_token,
        configuration: %{intake: _intake, policy: _policy, envelope: _envelope} = configuration
      }
      when is_pid(owner_pid) and is_reference(owner_token) ->
        if Process.alive?(owner_pid),
          do: safely_observe(log_event, configuration),
          else: :ignore

      _inactive_or_invalid ->
        :ignore
    end
  rescue
    _error -> :ignore
  catch
    _kind, _reason -> :ignore
  end

  def filter(log_event, configuration) when is_map(configuration) do
    safely_observe(log_event, configuration)
  end

  def filter(_log_event, _invalid_configuration), do: :ignore

  defp safely_observe(log_event, configuration) do
    if Internal.active?() do
      :ignore
    else
      observe(log_event, configuration)
    end
  rescue
    _error -> :ignore
  catch
    _kind, _reason -> :ignore
  end

  defp observe(log_event, configuration) do
    case Envelope.from_logger(log_event, Map.get(configuration, :envelope, %{})) do
      {:ok, envelope} ->
        decision =
          Internal.run(fn ->
            Policy.evaluate(
              envelope,
              Map.get(configuration, :policy, JournalAsh.Policy.Default)
            )
          end)

        case Intake.accept(envelope, decision, Map.get(configuration, :intake, JournalAsh.Intake)) do
          :ok ->
            if Decision.project?(decision, :standard_log), do: log_event, else: :stop

          {:dropped, reason} ->
            Emergency.report(reason)
            :ignore
        end

      {:error, reason} ->
        Emergency.report(reason)
        :ignore
    end
  end
end

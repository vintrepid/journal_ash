defmodule JournalAsh.Application do
  @moduledoc false

  use Application

  alias JournalAsh.{Config, EmergencyLimiter, Intake, LoggerIntegration, RuntimeConfiguration}

  @impl true
  def start(_type, _arguments) do
    configuration = Config.load()

    case start_configuration(configuration) do
      {:ok, supervisor, state} ->
        :ok = RuntimeConfiguration.register(supervisor, configuration)
        {:ok, supervisor, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec start_configuration(map(), keyword()) ::
          {:ok, pid(), map()} | {:error, term()}
  def start_configuration(configuration, options \\ []) do
    {store_module, store_options} = configuration.store
    supervisor_name = Keyword.get(options, :supervisor_name, JournalAsh.Supervisor)
    emergency_options = Keyword.get(options, :emergency_options, [])
    emergency_key = Keyword.get(emergency_options, :key, EmergencyLimiter.default_key())

    children = [
      {EmergencyLimiter, emergency_options},
      store_module.child_spec(store_options),
      {Intake,
       [
         name: configuration.intake,
         capacity: configuration.capacity,
         batch_size: configuration.batch_size,
         retry_interval: configuration.retry_interval,
         max_entry_attempts: configuration.max_entry_attempts,
         sweep_interval: configuration.sweep_interval,
         recent_drop_window: configuration.recent_drop_window,
         store: configuration.store
       ]}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: supervisor_name) do
      {:ok, supervisor} ->
        maybe_install(supervisor, configuration, emergency_key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def prep_stop(%{configuration: configuration} = state) do
    RuntimeConfiguration.unregister(state.supervisor)

    if state.installation do
      LoggerIntegration.uninstall(state.installation)
    end

    _flushed = Intake.flush(configuration.intake, configuration.flush_timeout)
    Intake.invalidate(configuration.intake)
    EmergencyLimiter.invalidate(state.emergency_key)
    state
  end

  defp maybe_install(
         supervisor,
         %{install_logger_filter: false} = configuration,
         emergency_key
       ) do
    {:ok, supervisor,
     %{
       configuration: configuration,
       emergency_key: emergency_key,
       installation: nil,
       supervisor: supervisor
     }}
  end

  defp maybe_install(supervisor, configuration, emergency_key) do
    case LoggerIntegration.install(configuration, supervisor) do
      {:ok, installation} ->
        {:ok, supervisor,
         %{
           configuration: configuration,
           emergency_key: emergency_key,
           installation: installation,
           supervisor: supervisor
         }}

      {:error, reason} ->
        Supervisor.stop(supervisor)
        Intake.invalidate(configuration.intake)
        EmergencyLimiter.invalidate(emergency_key)
        {:error, reason}
    end
  end
end

defmodule JournalAsh.TestLoggerHandler do
  @moduledoc false

  @behaviour :logger_handler

  @impl true
  def adding_handler(configuration), do: {:ok, configuration}

  @impl true
  def changing_config(_operation, _old_configuration, new_configuration),
    do: {:ok, new_configuration}

  @impl true
  def filter_config(configuration), do: configuration

  @impl true
  def removing_handler(_configuration), do: :ok

  @impl true
  def log(event, %{config: %{receiver: receiver}}) when is_pid(receiver) do
    send(receiver, {:test_logger_event, event})
    :ok
  end

  def log(_event, _configuration), do: :ok

  def filter(event, _extra), do: event
end

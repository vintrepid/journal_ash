defmodule JournalAsh.Envelope do
  @moduledoc """
  A bounded, normalized observation accepted from OTP Logger.

  An envelope is an observation that a process asked Logger to emit. It is not
  evidence that an Ash transaction committed. `JournalAsh.CommittedFact`
  defines that separate future integration boundary.
  """

  alias JournalAsh.{Limits, Sanitizer}

  @default_metadata_keys [
    :application,
    :domain,
    :event,
    :function,
    :line,
    :mfa,
    :module,
    :request_id,
    :resource,
    :span_id,
    :trace_id
  ]

  @event_pattern ~r/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/
  @maximum_event_bytes 160

  @enforce_keys [:id, :kind, :source, :event, :level, :message, :metadata, :observed_at]
  defstruct [:id, :kind, :source, :event, :level, :message, :metadata, :observed_at]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :observation,
          source: :logger,
          event: String.t(),
          level: atom(),
          message: String.t(),
          metadata: map(),
          observed_at: DateTime.t()
        }

  @doc false
  @spec metadata_keys() :: [atom()]
  def metadata_keys, do: @default_metadata_keys

  @spec from_logger(:logger.log_event(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_logger(log_event, options \\ [])

  def from_logger(%{level: level, msg: message} = log_event, options) when is_atom(level) do
    options = normalize_options(options)
    limits = Limits.new(Map.get(options, :limits, []))

    raw_metadata =
      case Map.get(log_event, :meta, %{}) do
        metadata when is_map(metadata) -> metadata
        _invalid -> %{}
      end

    metadata_keys = Map.get(options, :metadata_keys, @default_metadata_keys)
    capture_reports? = Map.get(options, :capture_reports, false)

    message_limit = min(limits.max_message_bytes, limits.max_total_bytes)
    {message, supplemental_metadata} = normalize_message(message, message_limit, capture_reports?)
    remaining_bytes = max(limits.max_total_bytes - byte_size(message), 0)

    raw_metadata =
      Enum.reduce(supplemental_metadata, raw_metadata, fn {key, value}, metadata ->
        Map.put(metadata, key, value)
      end)

    metadata_keys = include_supplemental_keys(metadata_keys, supplemental_metadata)

    metadata =
      raw_metadata
      |> Sanitizer.metadata(metadata_keys, limits, remaining_bytes)

    {:ok,
     %__MODULE__{
       id: Ash.UUIDv7.generate(),
       kind: :observation,
       source: :logger,
       event: event_name(raw_metadata),
       level: level,
       message: message,
       metadata: metadata,
       observed_at: observed_at(raw_metadata)
     }}
  rescue
    _error -> {:error, :invalid_logger_event}
  catch
    _kind, _reason -> {:error, :invalid_logger_event}
  end

  def from_logger(_log_event, _options), do: {:error, :invalid_logger_event}

  defp normalize_options(options) when is_map(options), do: options

  defp normalize_options(options) when is_list(options) do
    options
    |> take_options(16, [])
    |> Map.new()
  end

  defp normalize_options(_options), do: %{}

  defp normalize_message({:string, message}, maximum_bytes, _capture_reports?) do
    {Sanitizer.text(message, maximum_bytes), []}
  end

  defp normalize_message({:report, report}, maximum_bytes, true) do
    {Sanitizer.text("Logger report", maximum_bytes), [report: report]}
  end

  defp normalize_message({:report, _report}, maximum_bytes, false),
    do: {Sanitizer.text("Logger report", maximum_bytes), []}

  defp normalize_message({format, arguments}, maximum_bytes, true)
       when (is_binary(format) or is_list(format)) and is_list(arguments) do
    {Sanitizer.text(format, maximum_bytes), [format_arguments: arguments]}
  end

  defp normalize_message({format, arguments}, maximum_bytes, false)
       when (is_binary(format) or is_list(format)) and is_list(arguments) do
    {Sanitizer.text(format, maximum_bytes), []}
  end

  defp normalize_message(message, maximum_bytes, _capture_reports?) do
    {Sanitizer.text(message, maximum_bytes), []}
  end

  defp include_supplemental_keys(:all, _supplemental_metadata), do: :all

  defp include_supplemental_keys(metadata_keys, supplemental_metadata)
       when is_list(metadata_keys) do
    Enum.map(supplemental_metadata, &elem(&1, 0)) ++ metadata_keys
  end

  defp include_supplemental_keys(metadata_keys, _supplemental_metadata), do: metadata_keys

  defp take_options(_options, 0, result), do: Enum.reverse(result)
  defp take_options([], _remaining, result), do: Enum.reverse(result)

  defp take_options([{key, value} | rest], remaining, result) when is_atom(key),
    do: take_options(rest, remaining - 1, [{key, value} | result])

  defp take_options([_invalid | rest], remaining, result),
    do: take_options(rest, remaining - 1, result)

  defp take_options(_improper, _remaining, result), do: Enum.reverse(result)

  defp event_name(metadata) when is_map(metadata) do
    metadata
    |> Map.get(:event, Map.get(metadata, "event"))
    |> normalize_event_name()
  end

  defp event_name(_metadata), do: "logger.unstructured"

  defp normalize_event_name(event) when is_atom(event),
    do: event |> Atom.to_string() |> normalize_event_name()

  defp normalize_event_name(event) when is_binary(event) do
    if byte_size(event) <= @maximum_event_bytes and Regex.match?(@event_pattern, event) do
      :binary.copy(event)
    else
      "logger.unstructured"
    end
  end

  defp normalize_event_name(_event), do: "logger.unstructured"

  defp observed_at(metadata) when is_map(metadata) do
    case Map.get(metadata, :time, Map.get(metadata, "time")) do
      timestamp when is_integer(timestamp) ->
        case DateTime.from_unix(timestamp, :microsecond) do
          {:ok, datetime} -> datetime
          {:error, _reason} -> DateTime.utc_now()
        end

      _other ->
        DateTime.utc_now()
    end
  end

  defp observed_at(_metadata), do: DateTime.utc_now()
end

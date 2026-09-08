defmodule JournalAsh.Entry do
  @moduledoc """
  Canonical Ash value for an entry retained by a journal store.

  This embedded resource validates observations without imposing a database or
  repository on host applications. Durable adapters can map it to their own
  Ash resource. The only create action in this alpha records observations;
  committed facts require a later transaction-aware Ash integration.
  """

  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false

  alias JournalAsh.{Decision, Envelope}

  actions do
    defaults []

    create :record_observation do
      primary? true

      accept [
        :id,
        :source,
        :event,
        :level,
        :message,
        :metadata,
        :observed_at,
        :decision
      ]

      change JournalAsh.Entry.DetachObservation, only_when_valid?: true
    end
  end

  validations do
    validate JournalAsh.Entry.ValidObservation,
      on: [:create],
      only_when_valid?: true
  end

  attributes do
    attribute :id, :uuid_v7 do
      allow_nil? false
      primary_key? true
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      default :observation
      writable? false
      public? true
      constraints one_of: [:observation]
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:logger]
    end

    attribute :event, :string do
      allow_nil? false
      public? true

      constraints max_length: 160,
                  length_count: :bytes,
                  match: ~r/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/,
                  trim?: false
    end

    attribute :level, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :debug,
                    :info,
                    :notice,
                    :warning,
                    :error,
                    :critical,
                    :alert,
                    :emergency
                  ]
    end

    attribute :message, :string do
      allow_nil? false
      public? true
      sensitive? true

      constraints max_length: 8_192,
                  length_count: :bytes,
                  trim?: false,
                  allow_empty?: true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
      sensitive? true
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :decision, :map do
      allow_nil? false
      public? true
    end
  end

  @spec from_observation(Envelope.t(), Decision.t()) ::
          {:ok, t()} | {:error, Ash.Error.t() | :invalid_decision}
  def from_observation(%Envelope{} = envelope, %Decision{} = decision) do
    with {:ok, decision} <- Decision.validate(decision) do
      __MODULE__
      |> Ash.Changeset.for_create(:record_observation, %{
        id: envelope.id,
        source: envelope.source,
        event: envelope.event,
        level: envelope.level,
        message: envelope.message,
        metadata: envelope.metadata,
        observed_at: envelope.observed_at,
        decision: Decision.to_map(decision)
      })
      |> Ash.create()
    end
  end
end

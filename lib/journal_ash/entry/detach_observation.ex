defmodule JournalAsh.Entry.DetachObservation do
  @moduledoc false

  use Ash.Resource.Change

  alias JournalAsh.Entry.ValidObservation

  @impl true
  def change(changeset, _options, _context) do
    message = Ash.Changeset.get_attribute(changeset, :message)
    metadata = Ash.Changeset.get_attribute(changeset, :metadata)
    decision = Ash.Changeset.get_attribute(changeset, :decision)

    if changeset.valid? and
         ValidObservation.validate_values(message, metadata, decision) == :ok do
      changeset
      |> detach_attribute(:id)
      |> detach_attribute(:event)
      |> detach_attribute(:message)
      |> detach_attribute(:metadata)
      |> detach_attribute(:decision)
      |> normalize_observed_at()
    else
      changeset
    end
  end

  defp detach_attribute(changeset, attribute) do
    case Ash.Changeset.fetch_change(changeset, attribute) do
      {:ok, value} -> Ash.Changeset.change_attribute(changeset, attribute, detach(value))
      :error -> changeset
    end
  end

  defp normalize_observed_at(changeset) do
    case Ash.Changeset.fetch_change(changeset, :observed_at) do
      {:ok, %DateTime{} = datetime} ->
        normalized =
          datetime
          |> DateTime.to_unix(:microsecond)
          |> DateTime.from_unix!(:microsecond)

        Ash.Changeset.change_attribute(changeset, :observed_at, normalized)

      _missing_or_invalid ->
        changeset
    end
  end

  defp detach(value) when is_binary(value), do: :binary.copy(value)

  defp detach(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {detach(key), detach(nested)} end)
  end

  defp detach(value) when is_list(value), do: Enum.map(value, &detach/1)
  defp detach(value), do: value
end

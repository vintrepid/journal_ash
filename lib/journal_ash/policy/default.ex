defmodule JournalAsh.Policy.Default do
  @moduledoc """
  Conservative default policy: retain every accepted event and keep the
  conventional Logger projection enabled.
  """

  @behaviour JournalAsh.Policy

  alias JournalAsh.Decision

  @impl true
  def decide(_envelope, _options) do
    %Decision{retention: :retain, projections: [:standard_log], reason: :default}
  end
end

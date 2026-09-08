defmodule JournalAsh.TestInspectBomb do
  @moduledoc false
  defstruct [:value]
end

defimpl Inspect, for: JournalAsh.TestInspectBomb do
  def inspect(_value, _options), do: raise("inspect must not run")
end

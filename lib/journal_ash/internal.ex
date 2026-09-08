defmodule JournalAsh.Internal do
  @moduledoc false

  @process_key {__MODULE__, :active}

  @spec active?() :: boolean()
  def active?, do: Process.get(@process_key, false) == true

  @spec run((-> result)) :: result when result: var
  def run(function) when is_function(function, 0) do
    previous = Process.get(@process_key, false)
    Process.put(@process_key, true)

    try do
      function.()
    after
      if previous do
        Process.put(@process_key, previous)
      else
        Process.delete(@process_key)
      end
    end
  end
end

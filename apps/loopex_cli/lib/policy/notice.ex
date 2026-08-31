defmodule LoopexCli.Policy.Notice do
  @moduledoc false

  # Concept: a policy stance is announced once to the whole VM, even when many
  # tool decisions begin together.
  #
  # Technical depth: `persistent_term` retains the VM-wide fact but its
  # get-then-put sequence is not atomic. A local `:global` transaction supplies
  # that missing serialization. The resource id is shared while the requester id
  # is the calling process, so concurrent callers contend rather than appearing
  # to be re-entrant holders of the same lock.
  @spec once(term(), (-> term())) :: :ok
  def once(key, announce) when is_function(announce, 0) do
    case :persistent_term.get(key, :not_announced) do
      announced when announced != :not_announced ->
        :ok

      :not_announced ->
        lock_id = {{__MODULE__, key}, self()}

        case :global.trans(
               lock_id,
               fn -> announce_under_lock(key, announce) end,
               [node()],
               :infinity
             ) do
          :ok -> :ok
          {:aborted, reason} -> raise "policy notice lock failed: #{inspect(reason)}"
        end
    end
  end

  defp announce_under_lock(key, announce) do
    case :persistent_term.get(key, :not_announced) do
      announced when announced != :not_announced ->
        :ok

      :not_announced ->
        _ = announce.()
        :persistent_term.put(key, :announced)
        :ok
    end
  end
end

defmodule LoopexCli.Policy.Notice do
  @moduledoc false

  @silent_ask_json {__MODULE__, :silent_ask_json}

  # Concept: a one-shot JSON command emits only its result and keeps policy
  # decisions under the selected policy module.
  # Technical depth: main/1 calls this only in its dedicated escript VM after
  # valid JSON argv. That VM halts after rendering. An in-process Ask.run/2
  # never installs this marker, and no policy announcement key is written here.
  @doc false
  @spec silence_ask_json() :: :ok
  def silence_ask_json do
    :persistent_term.put(@silent_ask_json, true)
    :ok
  end

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
    if :persistent_term.get(@silent_ask_json, false) do
      :ok
    else
      announce_once(key, announce)
    end
  end

  defp announce_once(key, announce) do
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

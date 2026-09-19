defmodule Loopex.AppServer.Host do
  @moduledoc """
  ## Concept

  The shipped local host for this server: it reads an operator's launch inputs
  from the environment, composes the reference stack through `LoopexComposition`,
  and serves one connection on standard input and output until that input ends.

  It exists so the command in the operator guide is a command an operator can
  actually run. A guide that pointed at a test fixture would be documenting
  something that ships with the tests rather than with the product, and the only
  way to find that out would be to follow the instructions.

  Everything that decides what a session can do is chosen here, at launch, and
  nothing a client sends can change any of it: where durable state lives, which
  workspace the hands hold, which provider companion the adapter may start, and
  which host policy answers for authority. The credential is not among them —
  it stays in the environment, is read by the adapter itself, and never reaches
  an argument, a record or a log.

  ## Technical depth

  | Input | Meaning |
  | --- | --- |
  | `LOOPEX_HOME` | The state root. The session log, the artifact store and the receipt ledger live beneath it. |
  | `LOOPEX_WORKSPACE` | The workspace root the executor leases and project skills are discovered under. |
  | `LOOPEX_PROVIDER_LAUNCH` | The `.launch` file naming the provider companion this host may start. It carries no credential. |
  | `LOOPEX_POLICY` | `allow-all` or `ask`. There is no default: authority is the operator's to name. |
  | `LOOPEX_PROVIDER_API_KEY` | Read by the model adapter, never by this module. Its presence is checked so an unattended launch refuses in a second rather than at the first dispatch. |

  A missing or unusable input refuses on standard error and halts with status 3.
  Nothing but protocol records reaches standard output — the diagnostics sink is
  left unset and every message here goes to standard error — because a stray
  line would break a client parsing that stream by line.

  The composition is asked for two things beyond its defaults. It may break a
  writer marker left behind by a dead holder, because a successor started after
  an abrupt loss meets exactly that and the store still refuses a live holder
  whoever asked. And it wires artifact transfers, so a client can read back what
  a tool retained in bounded verified windows rather than being handed a path.

  `LoopexComposition.with_runtime/2` owns the lifetime rather than `start/1`: the
  process ends when its input ends, and a virtual machine that simply halts runs
  no `terminate/2`, so the durable store would keep its writer marker and refuse
  the next process. Returning through the bracket is what gives the marker back
  and makes an orderly close distinguishable from the abrupt loss this server
  also survives.
  """

  alias Loopex.AppServer.Policy
  alias Loopex.AppServer.Stdio
  alias LoopexComposition.{ResourcePacks, WorkspaceIdentity}

  @policies %{"allow-all" => Policy.AllowAll, "ask" => Policy.Ask}

  @doc """
  ## Concept

  Composes the runtime from the operator's launch inputs and serves one
  connection until standard input ends.

  ## Technical depth

  The workspace reference this host computed is written to standard error before
  the first frame is read. A client cannot derive it — the catalog withholds it
  along with every entry until a trust decision naming it is active — so an
  operator who is going to relay such a decision needs somewhere to read it, and
  standard error is the only plane that is not the protocol.
  """
  @spec serve() :: :ok
  def serve do
    case launch() do
      {:ok, options} ->
        announce(options)

        case LoopexComposition.with_runtime(options, &Stdio.serve/1) do
          :ok -> :ok
          other -> refuse("the composed runtime did not start or stop cleanly: #{inspect(other)}")
        end

      {:error, message} ->
        refuse(message)
    end
  end

  @doc """
  ## Concept

  The workspace reference for `LOOPEX_WORKSPACE`, for an operator assembling the
  trust decision a client will relay.

  ## Technical depth

  It is derived from the resolved workspace root and that directory's identity
  rather than chosen, so it is the same value this host will compute at launch
  and the same one the runtime binds a decision against. Refuses and halts if
  the workspace is absent or unreadable, so a shell substituting this into an
  environment variable gets a refusal rather than an empty string.
  """
  @spec workspace_reference!() :: binary()
  def workspace_reference! do
    case workspace() do
      {:ok, workspace} ->
        case WorkspaceIdentity.reference(workspace) do
          {:ok, reference} ->
            reference

          {:error, reason} ->
            refuse("the workspace reference could not be resolved: #{inspect(reason)}")
        end

      {:error, message} ->
        refuse(message)
    end
  end

  # Concept: every launch input, gathered and refused as one.
  #
  # Technical depth: the order is the order an operator would fix them in, and
  # the first refusal wins, so a launch missing three inputs names one at a time
  # rather than printing a wall an operator has to parse.
  defp launch do
    with {:ok, state_root} <- state_root(),
         {:ok, workspace} <- workspace(),
         {:ok, provider_launch} <- provider_launch(),
         {:ok, policy} <- policy(),
         :ok <- credential(),
         {:ok, runtime_id} <- runtime_id(state_root),
         {:ok, manifest} <- skills(workspace, state_root) do
      {:ok,
       [
         state_root: state_root,
         workspace: workspace,
         runtime_id: runtime_id,
         policy: policy,
         provider_launch: provider_launch,
         resource_manifest: manifest,
         recover_stale_writer: true,
         artifact_transfers: true
       ]}
    end
  end

  defp state_root do
    case Loopex.state_root() do
      {:ok, root} ->
        case File.mkdir_p(root) do
          :ok -> {:ok, root}
          {:error, reason} -> {:error, "LOOPEX_HOME is not usable: #{:file.format_error(reason)}"}
        end

      {:error, :loopex_home_required} ->
        {:error, "LOOPEX_HOME is required: it names the state root durable sessions live under"}

      {:error, reason} ->
        {:error, "LOOPEX_HOME could not be resolved: #{inspect(reason)}"}
    end
  end

  defp workspace do
    with {:ok, path} <- required("LOOPEX_WORKSPACE", "the workspace root the hands hold") do
      expanded = Path.expand(path)

      if File.dir?(expanded),
        do: {:ok, expanded},
        else: {:error, "LOOPEX_WORKSPACE does not name a directory: #{expanded}"}
    end
  end

  # Concept: the managed launch options of the provider companion this host is
  # allowed to start.
  #
  # Technical depth: they are read from the non-secret `.launch` file the
  # companion build emitted. They carry no credential, and the adapter refuses
  # before dispatch if they do not describe the artifact actually present.
  defp provider_launch do
    with {:ok, path} <-
           required("LOOPEX_PROVIDER_LAUNCH", "the provider companion's launch configuration") do
      case :file.consult(String.to_charlist(path)) do
        {:ok, [configuration]} when is_list(configuration) ->
          {:ok, configuration}

        _unreadable ->
          {:error,
           "LOOPEX_PROVIDER_LAUNCH does not name a readable launch configuration: #{path}"}
      end
    end
  end

  # Concept: authority is named by the operator and has no default.
  #
  # Technical depth: the composition refuses without a policy for the same
  # reason this refuses without a choice — a permissive fallback would answer a
  # question the operator never asked.
  defp policy do
    case System.get_env("LOOPEX_POLICY") do
      name when is_binary(name) and name != "" ->
        case Map.fetch(@policies, name) do
          {:ok, module} ->
            {:ok, module}

          :error ->
            {:error,
             "LOOPEX_POLICY must be one of #{Enum.join(Enum.sort(Map.keys(@policies)), ", ")}, " <>
               "and was #{inspect(name)}"}
        end

      _absent ->
        {:error,
         "LOOPEX_POLICY is required: name the host policy that answers for this " <>
           "server's authority (#{Enum.join(Enum.sort(Map.keys(@policies)), " or ")})"}
    end
  end

  # Concept: a host that spends a real credential says so before it starts.
  #
  # Technical depth: the value is never read into a variable that outlives this
  # check, never logged and never passed onward; the adapter reads the variable
  # itself after its companion is ready.
  defp credential do
    case System.get_env("LOOPEX_PROVIDER_API_KEY") do
      value when is_binary(value) and value != "" ->
        :ok

      _absent ->
        {:error,
         "LOOPEX_PROVIDER_API_KEY is required: the model adapter reads it from the " <>
           "environment and it is never passed on a command line or written to disk"}
    end
  end

  defp runtime_id(state_root) do
    case Loopex.runtime_placement_id(state_root) do
      {:ok, runtime_id} ->
        {:ok, runtime_id}

      {:error, reason} ->
        {:error, "the runtime placement identity could not be read: #{inspect(reason)}"}
    end
  end

  # Concept: the project skills the workspace already holds, offered to a client
  # that carries an operator's trust decision.
  #
  # Technical depth: discovery is the same walk the command performs, so what a
  # client can select here is what the workspace admits there. A workspace with
  # no `.agents/skills` yields a manifest with no packs rather than a refusal,
  # because having no skills is an ordinary state and not a launch error.
  defp skills(workspace, state_root) do
    with {:ok, workspace_ref} <- workspace_ref(workspace) do
      case ResourcePacks.discover(workspace,
             workspace_ref: workspace_ref,
             state_root: state_root
           ) do
        {:ok, manifest} ->
          {:ok, manifest}

        {:error, {reason, detail}} ->
          {:error, "the workspace's project skills could not be read: #{reason} (#{detail})"}
      end
    end
  end

  defp workspace_ref(workspace) do
    case WorkspaceIdentity.reference(workspace) do
      {:ok, reference} ->
        {:ok, reference}

      {:error, reason} ->
        {:error, "the workspace reference could not be resolved: #{inspect(reason)}"}
    end
  end

  defp announce(options) do
    case workspace_ref(Keyword.fetch!(options, :workspace)) do
      {:ok, reference} ->
        IO.puts(:stderr, "loopex app-server: the workspace reference is #{reference}")

      {:error, _message} ->
        :ok
    end
  end

  defp required(name, meaning) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, "#{name} is required: it names #{meaning}"}
    end
  end

  @spec refuse(binary()) :: no_return()
  defp refuse(message) do
    IO.puts(:stderr, "loopex app-server: " <> message)
    System.halt(3)
  end
end

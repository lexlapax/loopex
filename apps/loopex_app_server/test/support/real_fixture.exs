_ = System.fetch_env!("LOOPEX_HOME")

defmodule Loopex.AppServer.RealFixture do
  @moduledoc """
  ## Concept

  The launch configuration a server process runs under when the workflow is
  driven by a real provider: the reference model adapter calling the pinned
  model, the local Store on the operator's path, the trusted local executor
  with the shipped coding tools, the local artifact store that serves bounded
  transfers, and the same host policy that asks before it allows.

  It is the scripted fixture's twin. Everything a client can observe is the
  same, because only the model and the hands behind the wire changed; what a
  client sends, answers and reads is identical, which is what makes the two
  lanes comparable evidence about one protocol.

  ## Technical depth

  Every input is a launch input read from the environment, as accepted ADR 0023
  requires: where the session lives, which workspace the executor leases, and
  which provider companion the adapter is allowed to start. The provider
  credential is read by the adapter itself from `LOOPEX_PROVIDER_API_KEY` and is
  never passed on a command line, written to disk or printed; this module only
  establishes that one is present before a run begins, so an unattended
  invocation refuses immediately instead of failing at dispatch.

  The four implementations are named here rather than taken from
  `LoopexComposition`, which composes the same Store, adapter, executor and
  artifact store but hands the runtime no artifact store at all and starts no
  transfer owner. A runtime composed that way refuses `artifact.open_transfer`
  with `artifact_transfer_unsupported`, so the bounded transfer leg of this
  workflow could not run through it. Naming one artifact store for the executor
  to spill into and for the runtime to serve transfers from is exactly what that
  leg needs, and it is the only difference from the reference wiring.

  Only `loopex.read` is active. The shipped tool set is declared whole, because
  what a host declares is what a reviewer should see, but a run that is asked to
  read one file needs one tool and a narrower active set is an ordinary host
  selection. It is also what keeps the evidence behavioral rather than
  hopeful: the assertion is that the tool ran after the answer committed and
  that exactly one artifact crossed, not that a particular sentence came back.
  """

  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.LLM.ReqLLM
  alias Loopex.Store
  alias Loopex.Store.Local, as: LocalStore
  alias Loopex.Store.Local.{Artifacts, Transfers}

  @doc """
  ## Concept

  Composes the real runtime and serves one connection on standard input and
  output.

  ## Technical depth

  Nothing but protocol records reaches standard output: the diagnostics sink is
  left unset, and every refusal this module raises is written to standard error
  before the process halts, because a stray line would break a client parsing
  this stream by line.

  The process ends when its input ends. The Store is stopped explicitly on that
  path so its writer marker is given back, which is what makes an orderly close
  distinguishable from the abrupt loss this workflow also exercises.
  """
  @spec serve() :: :ok
  def serve do
    {runtime, store_pid} = compose()
    Loopex.AppServer.Stdio.serve(runtime)
    GenServer.stop(store_pid, :normal, 5_000)
  end

  # Concept: one runtime wired from the launch inputs an operator supplied.
  #
  # Technical depth: the Store path is required rather than defaulted, because
  # the restart leg is only a restart if the session outlives the process, and a
  # fixture that quietly fell back to an in-memory Store would report a
  # successful resume of a session that had never been durable.
  defp compose do
    store_path = required("LOOPEX_WORKFLOW_STORE")
    workspace = required("LOOPEX_WORKSPACE")
    state_root = Path.dirname(store_path)
    launch = provider_launch()
    credential!()

    for application <- [:loopex, :loopex_store_local, :loopex_executor_local] do
      {:ok, _started} = Application.ensure_all_started(application)
    end

    File.mkdir_p!(state_root)

    # A successor started after an abrupt loss meets a writer marker its dead
    # predecessor never gave back, so it is allowed to break one. The Store
    # establishes the holder's liveness itself and refuses a live one however
    # this option is set, so the single-writer rule stands.
    {:ok, store_pid} = LocalStore.start_link(path: store_path, recover_stale_writer: true)
    {:ok, store} = Store.new(LocalStore, store_pid)

    spill = artifact_store(state_root)
    tools = CodingTools.definitions()

    {:ok, lease} =
      WorkspaceLease.start_link(id: "workspace", path: workspace, fencing_token: 1)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(state_root, "receipts"),
        artifacts: spill
      )

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "app-server-real-workflow",
        store: store,
        context_token_budget: 32_768,
        model: %{module: ReqLLM, model: ReqLLM.default_model(), options: launch},
        executor: %{
          module: Local,
          reference: executor,
          identity: "executor-local",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace"
        },
        tool: nil,
        tools: tools,
        active_tools: ["loopex.read"],
        bounds: %{max_turns: 6, token_budget: 1_000_000, deadline_ms: 600_000},
        sampling: %{"max_tokens" => 512},
        resource_manifest: skill_manifest(),
        artifact_store: spill,
        policy: Loopex.AppServer.WorkflowPolicy,
        policy_identity: %{"id" => "loopex.app_server.workflow_policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    {runtime, store_pid}
  end

  # Concept: one artifact store, spilled into by the hands and read from by the
  # runtime.
  #
  # Technical depth: the transfer owner is a process the handle carries rather
  # than a named global, so the descriptors of this placement belong to this
  # runtime. Without it the adapter refuses the whole transfer family, which is
  # why it is started here and not assumed.
  defp artifact_store(state_root) do
    root = Path.join(state_root, "artifacts")
    {:ok, handle} = Artifacts.open(root)
    {:ok, transfers} = Transfers.start_link(root: root)
    %{module: Artifacts, handle: Map.put(handle, :transfers, transfers)}
  end

  # Concept: the four managed launch options of the provider companion this host
  # is allowed to start.
  #
  # Technical depth: they are read from the non-secret `.launch` file the
  # companion build emitted, named by the launching host. They carry no
  # credential, and the adapter refuses before dispatch if they do not describe
  # the artifact actually present.
  defp provider_launch do
    path = required("LOOPEX_WORKFLOW_PROVIDER_LAUNCH")

    case :file.consult(String.to_charlist(path)) do
      {:ok, [configuration]} when is_list(configuration) ->
        configuration

      _unreadable ->
        refuse("LOOPEX_WORKFLOW_PROVIDER_LAUNCH does not name a readable launch configuration")
    end
  end

  # Concept: a lane that spends a real credential says so before it starts.
  #
  # Technical depth: the value is never read into a variable that outlives this
  # check, never logged and never passed onward; the adapter reads the variable
  # itself after its companion is ready. An absent credential refuses here so an
  # unattended run fails in a second rather than at the first dispatch.
  defp credential! do
    case System.get_env("LOOPEX_PROVIDER_API_KEY") do
      value when is_binary(value) and value != "" ->
        :ok

      _absent ->
        refuse(
          "LOOPEX_PROVIDER_API_KEY is required: this workflow calls a real provider " <>
            "and the credential is supplied only through the environment"
        )
    end
  end

  defp required(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _absent -> refuse("#{name} is a required launch input of the real workflow fixture")
    end
  end

  defp refuse(message) do
    IO.puts(:stderr, "loopex real workflow fixture: " <> message)
    System.halt(3)
  end

  # Concept: one admitted skill for the client to find, read about and select.
  #
  # Technical depth: the workspace reference is a launch input and appears
  # nowhere a client can read it. Its files travel inside the manifest, so the
  # skill a client selects is the same one whatever the workspace holds, and the
  # only thing the real run adds is that a real model reads it.
  defp skill_manifest do
    files =
      for {label, content} <- [
            {"SKILL.md",
             "Read the file the operator names, using the read tool exactly once. " <>
               "Then report whether the result you received was complete."},
            {"notes.txt", "The workspace file architecture.txt is larger than one tool response."}
          ] do
        %{
          label: label,
          content: content,
          size: byte_size(content),
          digest: LoopexProtocol.Canonical.digest_bytes(content),
          contained: true
        }
      end

    %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: [
        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: "reader",
          description: "Reads a named workspace file",
          manual_only: true,
          files: files
        }
      ]
    }
  end
end

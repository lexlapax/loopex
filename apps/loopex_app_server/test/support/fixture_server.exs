defmodule Loopex.AppServer.Fixture do
  @moduledoc """
  ## Concept

  The launch configuration a server process runs under in outcome 5's workflow:
  a real runtime with a scripted model, a tool the model calls, an executor that
  retains an artifact, and a host policy that asks before it allows.

  ## Technical depth

  Accepted ADR 0023 keeps launch inputs outside the protocol, so this is where
  they live. The client driving this process cannot change any of it, which is
  as much a part of the demonstration as the workflow itself: a session runs
  under the store, model, executor and policy an operator chose at launch,
  whatever a later frame asks for.

  The model is scripted rather than real. The provider demonstration outcome 5
  also names is attended and spends a real key, so it stays the maintainer's to
  perform; everything a client can observe about the protocol is proved here
  without one.
  """

  @doc """
  ## Concept

  Composes the runtime and serves one connection on standard input and output.

  ## Technical depth

  Nothing is written to standard output but protocol records: the runtime's
  diagnostics sink is left unset, because a stray line would break every client
  parsing this stream by line. The process ends when its input ends, which makes
  the client's close a clean shutdown rather than a kill.

  Which script the model follows is chosen by the launching host through an
  environment variable, not by a frame. The plain script answers and stops; the
  tool script calls a tool whose authorization the policy defers, which is what
  drives the interaction and artifact legs.
  """
  @spec serve() :: :ok
  def serve do
    case System.get_env("LOOPEX_WORKFLOW_SCRIPT") do
      "tool" ->
        # The launching fixture owns this temporary home across server restarts.
        # Its retained objects must survive the predecessor's normal shutdown.
        root = Path.join(System.fetch_env!("LOOPEX_HOME"), "workflow-artifacts")
        {:ok, handle} = Loopex.Store.Local.Artifacts.open(root)
        {:ok, owner} = Loopex.Store.Local.Transfers.start_link(root: root)
        monitor = Process.monitor(owner)

        try do
          artifact_store = %{
            module: Loopex.Store.Local.Artifacts,
            handle: Map.put(handle, :transfers, owner)
          }

          serve(tool_options(artifact_store))
        after
          cutoff = System.monotonic_time(:millisecond) + 5_000

          :ok =
            GenServer.stop(owner, :normal, max(cutoff - System.monotonic_time(:millisecond), 0))

          receive do
            {:DOWN, ^monitor, :process, ^owner, :normal} ->
              if System.monotonic_time(:millisecond) >= cutoff,
                do: raise("original transfer owner cleanup exceeded its observation bound")
          after
            max(cutoff - System.monotonic_time(:millisecond), 0) ->
              raise "original transfer owner cleanup was not joined"
          end
        end

      # A model that prepares authored configuration, so a client can
      # configure and compact the live session it creates.
      "maintenance" ->
        serve(script: [], model_module: Loopex.AgentLoopPreparingModel)

      # One answered prompt, then a real summary for an explicit compact.
      "compaction" ->
        fixture = Loopex.AgentLoopFixture

        serve(
          [script: [%{text: "done", calls: []}, fixture.summary_reply()], tools: []] ++
            fixture.maintenance_options()
        )

      _plain ->
        serve(script: [%{text: "the task is done", calls: []}])
    end
  end

  defp serve(options) do
    store = durable_store()

    # Like the shipped host, the runtime's transient progress is routed to the
    # one Stdio connection through a sink this process owns.
    {:ok, sink} = Loopex.ProgressSink.open()

    try do
      fixture = Loopex.AgentLoopFixture.start(options ++ store ++ [progress_sink: sink])
      :ok = Loopex.AppServer.Stdio.serve(fixture.runtime, sink)
    after
      Loopex.ProgressSink.close(sink)

      # Ending input ends the process, and a virtual machine that simply halts runs
      # no `terminate/2`. A durable Store would then keep its writer marker and
      # refuse the next process, so the shutdown is orderly here rather than
      # abrupt: the Store is stopped, which is what gives the marker back.
      case Keyword.get(store, :store) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 5_000)
      end
    end
  end

  # Concept: a run that calls a tool and keeps what it produced.
  #
  # Technical depth: the model asks for one tool call and then finishes, the
  # policy defers that call until an operator answers, and the executor returns
  # a retained artifact reference for it. That gives a client every leg of the
  # chain to observe: the question, its answer, the committed authorization, the
  # tool finishing, and an artifact it can open a transfer against.
  defp tool_options(artifact_store) do
    producer = fn job ->
      {:ok, reference} =
        Loopex.ArtifactStore.put(artifact_store, "the file the tool wrote", %{
          "media_type" => "text/plain",
          "role" => "tool_output",
          "session_id" => job.session_id,
          "run_id" => job.run_id,
          "operation_id" => job.operation_id,
          "attempt" => job.attempt,
          "tool_call_id" => job.tool_call_id
        })

      [reference]
    end

    [
      artifact_store: artifact_store,
      artifacts: %{"workflow-call" => producer},
      resource_manifest: skill_manifest(),
      script: [
        %{
          text: "writing the file",
          calls: [%{id: "workflow-call", name: "write", arguments: %{"path" => "output.txt"}}]
        },
        %{text: "the task is done", calls: []}
      ],
      # The shipped asking policy, not a second one written for the tests: the
      # question a client renders and the identities it answers with are product
      # behaviour, so the scripted lane and the real lane must observe the same
      # ones or they are not comparable evidence about one protocol.
      policy: Loopex.AppServer.Policy.Ask,
      policy_identity: %{"id" => "loopex.app_server.policy.ask", "revision" => "1"}
    ]
  end

  # Concept: one admitted skill for the client to find, read about and select.
  #
  # Technical depth: the workspace reference is a launch input and appears
  # nowhere a client can read it, which is the point. A client that wants this
  # manifest admitted must carry an operator's decision naming the same
  # reference; it cannot derive one from the catalog, because the catalog
  # withholds both the reference and every entry until a decision is active.
  defp skill_manifest do
    files =
      for {label, content} <- [
            {"SKILL.md", "Write the file the operator asked for."},
            {"notes.txt", "Supporting notes."}
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
          name: "writer",
          description: "Writes an output file",
          manual_only: true,
          files: files
        }
      ]
    }
  end

  # Concept: a Store that outlives the process serving it, when the launching
  # host asks for one.
  #
  # Technical depth: outcome 5 restarts a server over one session, which only
  # means anything if the session is still there afterwards. The path comes from
  # the environment for the same reason every other launch input does: a frame
  # cannot choose where a session lives. Without it the fixture keeps its
  # in-memory Store, which is what a case that only drives one process wants.
  defp durable_store do
    case System.get_env("LOOPEX_WORKFLOW_STORE") do
      nil ->
        []

      path ->
        File.mkdir_p!(Path.dirname(path))

        # A successor started after an abrupt loss meets a writer marker its dead
        # predecessor never gave back, so it is allowed to break one. This takes
        # nothing away: a marker whose holder is still alive refuses an opener
        # however this option is set, so the one live writer rule stands and only
        # a marker nobody holds can be reclaimed.
        # The Store module is a launch input rather than a compile-time link: this
        # application does not depend on the edge one that provides it, and a host
        # composing a different Store would name a different module here.
        store_module = Module.concat(["Loopex", "Store", "Local"])
        {:ok, pid} = store_module.start_link(path: path, recover_stale_writer: true)
        [store: pid, store_module: store_module]
    end
  end
end

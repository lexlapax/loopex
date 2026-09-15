defmodule Loopex.AppServer.WorkflowArtifacts do
  @moduledoc """
  ## Concept

  The smallest artifact store that can serve a verified transfer: it keeps the
  bytes it was given, hands back the compact reference a client later presents,
  and reads that object in bounded windows.

  ## Technical depth

  It exists so outcome 5's artifact leg is a real crossing rather than a shape.
  Accepted ADR 0028's transfer triple is implemented here in full, so what a
  client opens, reads and closes is the same path a production store serves; a
  fixture that stopped at `put` would prove the wire and not the transfer.
  """

  @behaviour Loopex.ArtifactStore

  alias LoopexProtocol.Canonical

  def start, do: Agent.start_link(fn -> %{objects: %{}, uses: %{}, transfers: %{}} end)

  @impl Loopex.ArtifactStore
  def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
    digest = Canonical.digest_bytes(bytes)
    object = %{digest: digest, size: byte_size(bytes), locator: "workflow:" <> digest}

    use_record = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: media_type,
      role: role,
      metadata: metadata
    }

    use_digest = Canonical.digest(["artifact-use-v2", use_record])

    reference =
      Map.merge(object, %{
        media_type: media_type,
        role: role,
        use_canonicalization_version: Canonical.version(),
        use_digest: use_digest,
        use_locator: "use:" <> use_digest
      })

    Agent.update(pid, fn state ->
      %{
        state
        | objects: Map.put(state.objects, object.locator, {object, bytes}),
          uses: Map.put(state.uses, reference.use_locator, use_record)
      }
    end)

    {:ok, reference}
  end

  @impl Loopex.ArtifactStore
  def fetch(pid, object) do
    case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
      {:ok, {_object, bytes}} -> {:ok, bytes}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def stat(pid, locator) do
    case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
      {:ok, {object, _bytes}} -> {:ok, object}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def describe(pid, use_locator) do
    case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
      {:ok, use_record} -> {:ok, use_record}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def open_transfer(pid, object, use_locator, window) do
    case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
      {:ok, {stored, bytes}} ->
        start = Map.get(window, :start, 0)
        length = Map.get(window, :length, stored.size - start)

        if start > stored.size or start + length > stored.size do
          {:error, :invalid_window}
        else
          ref = "workflow-transfer-" <> Integer.to_string(System.unique_integer([:positive]))

          transfer = %{
            transfer_ref: ref,
            object: stored,
            use_locator: use_locator,
            total_size: stored.size,
            window_start: start,
            window_length: length,
            object_digest: stored.digest
          }

          Agent.update(pid, fn state ->
            %{state | transfers: Map.put(state.transfers, ref, {transfer, bytes, start})}
          end)

          {:ok, transfer}
        end

      :error ->
        {:error, :object_missing}
    end
  end

  @impl Loopex.ArtifactStore
  def read_transfer(pid, transfer, length) do
    case Agent.get(pid, &Map.fetch(&1.transfers, transfer.transfer_ref)) do
      {:ok, {held, bytes, position}} ->
        remaining = held.window_start + held.window_length - position

        if remaining <= 0 do
          {:ok, :complete}
        else
          take = min(length, remaining)
          chunk = binary_part(bytes, position, take)

          Agent.update(pid, fn state ->
            %{
              state
              | transfers:
                  Map.put(state.transfers, held.transfer_ref, {held, bytes, position + take})
            }
          end)

          {:ok, %{offset: position, bytes: chunk, chunk_digest: Canonical.digest_bytes(chunk)}}
        end

      :error ->
        {:error, :transfer_unknown}
    end
  end

  @impl Loopex.ArtifactStore
  def close_transfer(pid, transfer) do
    Agent.update(pid, fn state ->
      %{state | transfers: Map.delete(state.transfers, transfer.transfer_ref)}
    end)

    :ok
  end
end

defmodule Loopex.AppServer.WorkflowPolicy do
  @moduledoc """
  ## Concept

  A host policy that asks before it allows. The first time a tool call reaches
  it there is no answer to read, so it defers with a bounded question; once an
  operator's answer has committed, the same policy is asked again and decides on
  what that answer says.

  ## Technical depth

  This is the shape accepted ADR 0024 exists for, and the workflow needs a
  policy that genuinely has two outcomes rather than one that always allows. An
  answer is an input to this decision and never the decision itself: the allow
  is minted here, by the host, after the answer committed, which is what the
  chain outcome 5 names is meant to demonstrate end to end.
  """

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(request) do
    case Map.get(request, :interaction_response) do
      nil ->
        {:defer,
         %{
           kind: :choice,
           prompt: "May the tool write the file?",
           choices: [%{id: "allow", label: "Allow once"}, %{id: "deny", label: "Deny"}],
           expires_in_ms: 60_000
         }}

      %{answer: %{choice_id: "allow"}} ->
        {:allow, nil}

      %{answer: %{choice_id: _refused}} ->
        {:deny, :policy_denied}
    end
  end
end

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
    options =
      case System.get_env("LOOPEX_WORKFLOW_SCRIPT") do
        "tool" -> tool_options()
        _plain -> [script: [%{text: "the task is done", calls: []}]]
      end

    store = durable_store()
    fixture = Loopex.AgentLoopFixture.start(options ++ store)
    Loopex.AppServer.Stdio.serve(fixture.runtime)

    # Ending input ends the process, and a virtual machine that simply halts runs
    # no `terminate/2`. A durable Store would then keep its writer marker and
    # refuse the next process, so the shutdown is orderly here rather than
    # abrupt: the Store is stopped, which is what gives the marker back.
    case Keyword.get(store, :store) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  end

  # Concept: a run that calls a tool and keeps what it produced.
  #
  # Technical depth: the model asks for one tool call and then finishes, the
  # policy defers that call until an operator answers, and the executor returns
  # a retained artifact reference for it. That gives a client every leg of the
  # chain to observe: the question, its answer, the committed authorization, the
  # tool finishing, and an artifact it can open a transfer against.
  defp tool_options do
    {:ok, artifacts} = Loopex.AppServer.WorkflowArtifacts.start()

    {:ok, reference} =
      Loopex.AppServer.WorkflowArtifacts.put(artifacts, "the file the tool wrote", %{
        media_type: "text/plain",
        role: "tool_output",
        metadata: %{}
      })

    [
      artifact_store: %{module: Loopex.AppServer.WorkflowArtifacts, handle: artifacts},
      artifacts: %{"workflow-call" => [reference]},
      resource_manifest: skill_manifest(),
      script: [
        %{
          text: "writing the file",
          calls: [%{id: "workflow-call", name: "write", arguments: %{"path" => "output.txt"}}]
        },
        %{text: "the task is done", calls: []}
      ],
      policy: Loopex.AppServer.WorkflowPolicy,
      policy_identity: %{"id" => "loopex.app_server.workflow_policy", "revision" => "1"}
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

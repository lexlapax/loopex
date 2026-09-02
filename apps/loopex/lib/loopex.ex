defmodule Loopex do
  @moduledoc """
  ## Concept

  The direct embedded facade for explicit Loopex runtime instances. A host
  starts each runtime with its Store and bounded delivery configuration, creates
  or resumes durable sessions, attaches at a public-event cursor, admits
  commands, and consumes committed events without owning another session loop.

  ## Technical depth

  Every operation delegates to `Loopex.Runtime` or the runtime embedded in an
  opaque `Loopex.Attachment`. No application callback creates a default
  instance, and no application environment, registered name, persistent term,
  or Store implementation is selected here. M0 feasibility modules remain
  separately callable for their retained evidence but are not the M1 runtime
  path.
  """

  alias Loopex.Attachment
  alias Loopex.Runtime
  alias Loopex.SessionDirectory

  @version Mix.Project.config()[:version]

  @doc """
  ## Concept

  The single version both applications carry.

  ## Technical depth

  Read from the umbrella's `VERSION` file at compile time, so it cannot diverge
  from `LoopexProtocol.version/0` without changing one source.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  ## Concept

  Starts one supervised runtime from explicit configuration.

  ## Technical depth

  The returned opaque reference is required by every runtime-scoped operation.
  The process tree is unnamed and no implicit instance is installed.
  """
  @spec start_link([Runtime.option()]) :: {:ok, Runtime.t()} | {:error, term()}
  def start_link(options), do: Runtime.start_link(options)

  @doc """
  ## Concept

  Stops an explicit runtime and its transient session and attachment processes.

  ## Technical depth

  Durable Store history is not deleted. A later runtime using the same Store
  must explicitly resume any session and thereby commit fresh ownership.
  """
  @spec stop(Runtime.t()) :: :ok | {:error, term()}
  def stop(runtime), do: Runtime.stop(runtime)

  @doc """
  ## Concept

  Creates a durable session idempotently under one runtime command ID.

  ## Technical depth

  Session options become the `options` member of the `session_genesis_v2`
  payload of the Store's atomic runtime-control transaction; the runtime's
  committed cleanup period becomes its `runtime_configuration`. The complete
  canonical item is measured before the transaction, so an oversized
  configuration is `session_configuration_too_large` rather than an incidental
  Store error after session authority was acquired. Acknowledgement waits for
  both that commit and a fresh session-owner succession. Exact command
  re-presentation returns the retained session ID; changed canonical genesis
  conflicts.
  """
  @spec create_session(Runtime.t(), map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def create_session(runtime, session_options, options)
      when is_map(session_options) and is_list(options) do
    with {:ok, command_id} <- Keyword.fetch(options, :command_id) do
      Runtime.create_session(runtime, command_id, session_options)
    else
      :error -> {:error, :command_id_required}
    end
  end

  def create_session(_runtime, _session_options, _options),
    do: {:error, :invalid_session_creation}

  @doc """
  ## Concept

  Resumes a durable session under a fresh Store-backed owner.

  ## Technical depth

  The new coordinator is not routed or command-ready until `advance_owner`
  commits and complete private/public history is reconstructed.
  """
  @spec resume_session(Runtime.t(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def resume_session(runtime, session_id, options) when is_list(options) do
    with {:ok, command_id} <- Keyword.fetch(options, :command_id) do
      Runtime.resume_session(runtime, session_id, command_id)
    else
      :error -> {:error, :command_id_required}
    end
  end

  def resume_session(_runtime, _session_id, _options), do: {:error, :invalid_session_resume}

  @doc """
  ## Concept

  Atomically attaches one caller to a session snapshot and durable-event cursor.

  ## Technical depth

  Without `:after_event_sequence`, the snapshot anchors to the current outbox
  tail. A supplied retained cursor anchors replay there. Attachment state and
  request metadata remain transient and disappear on dispatcher or runtime
  restart.
  """
  @spec attach(Runtime.t(), binary(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  def attach(runtime, session_id, options \\ []),
    do: Runtime.attach(runtime, session_id, options)

  @doc """
  ## Concept

  Admits a prompt or abort through the session reached by this attachment.

  ## Technical depth

  Prompt maps carry `:type`, `:command_id`, and bounded binary `:content`; abort
  maps carry `:type` and `:command_id`. Durable command identity, active-run
  exclusion, and post-commit ownership fencing are enforced below the facade.
  """
  @spec command(Attachment.t(), map()) :: {:accepted, binary()} | {:error, term()}
  def command(attachment, command), do: Runtime.command(attachment, command)

  @doc """
  ## Concept

  Returns the authoritative snapshot captured by an attachment.

  ## Technical depth

  The snapshot is anchored to its exact durable `event_sequence`; it is not a
  live process-state read and does not advance as events are consumed.
  """
  @spec snapshot(Attachment.t()) :: map()
  def snapshot(attachment), do: Attachment.snapshot(attachment)

  @doc """
  ## Concept

  Consumes the next committed durable event for an attachment.

  ## Technical depth

  The Store-stamped event is returned unchanged. Empty is transient;
  disconnection returns the last consumed durable sequence for exact reattach.
  """
  @spec next_event(Attachment.t()) ::
          {:ok, map()} | {:disconnected, non_neg_integer()} | {:error, term()}
  def next_event(attachment), do: Runtime.next_event(attachment)

  @doc """
  ## Concept

  Observes bounded transient delivery state for one attachment.

  ## Technical depth

  Queue depth, maximum observed depth, capacity, status, and stable cursor are
  diagnostics only. They disappear on dispatcher restart and cannot authorize
  a command or replace durable event history.
  """
  @spec attachment_status(Attachment.t()) :: {:ok, map()} | {:error, term()}
  def attachment_status(attachment), do: Runtime.attachment_status(attachment)

  @doc """
  ## Concept

  Emits best-effort transient progress for one live attachment.

  ## Technical depth

  Progress accepts only bounded plain data, takes no Store mutation path, and
  may be dropped with the attachment or its configured sink.
  """
  @spec progress(Attachment.t(), term()) :: :ok | {:error, term()}
  def progress(attachment, item), do: Runtime.progress(attachment, item)

  @doc """
  ## Concept

  Emits one best-effort administrative diagnostic from an explicit runtime.

  ## Technical depth

  Diagnostics accept bounded plain data and are sent only to the runtime's
  configured transient sink. They never enter private history or the outbox.
  """
  @spec diagnostic(Runtime.t(), term()) :: :ok | {:error, term()}
  def diagnostic(runtime, item), do: Runtime.diagnostic(runtime, item)

  @doc """
  ## Concept

  Observes the current runtime-owned session projection.

  ## Technical depth

  The result omits owner-incarnation capability, Store handles, command content,
  and attachment state. It is reached only through the supplied runtime and is
  not a mutation or authority grant.
  """
  @spec session_status(Runtime.t(), binary()) :: {:ok, map()} | {:error, term()}
  def session_status(runtime, session_id), do: Runtime.session_status(runtime, session_id)

  @doc """
  ## Concept

  Opens the current recovery question for an effect whose durable intent has no
  committed fact.

  ## Technical depth

  The query is transient and owner-scoped. It carries the complete values a
  response must echo and does not dispatch or retry the effect.
  """
  @spec reconciliation_query(Attachment.t()) :: {:ok, map()} | {:error, term()}
  def reconciliation_query(attachment), do: Runtime.reconciliation_query(attachment)

  @doc """
  ## Concept

  Offers retained executor evidence—or explicit insufficient evidence—to the
  current session owner.

  ## Technical depth

  Only a response to the current solicited query can commit a receipt fact or
  `outcome_unknown`. The caller supplies evidence; the runtime validates and
  owns the durable transition.
  """
  @spec reconcile(Attachment.t(), map()) :: :ok | {:error, term()}
  def reconcile(attachment, response), do: Runtime.reconcile(attachment, response)

  @doc """
  ## Concept

  Resolves this host's session-directory state root, the anchor an operator
  needs to find and continue earlier work.

  ## Technical depth

  Delegates to `Loopex.SessionDirectory.state_root/0`, which reads only the
  `LOOPEX_HOME` process environment variable and never application environment.
  """
  @spec state_root() :: {:ok, Path.t()} | {:error, :loopex_home_required}
  def state_root, do: SessionDirectory.state_root()

  @doc """
  ## Concept

  This host's durable runtime placement identity for a resolved state root,
  generating and persisting one on first use.

  ## Technical depth

  Delegates to `Loopex.SessionDirectory.runtime_id/1`. A later call against the
  same state root, including one from a fresh operating-system process,
  re-presents the same value rather than generating a new one.
  """
  @spec runtime_placement_id(Path.t()) :: {:ok, binary()} | {:error, term()}
  def runtime_placement_id(state_root), do: SessionDirectory.runtime_id(state_root)

  @doc """
  ## Concept

  Records a session as known to the operator's session directory, bound to the
  runtime placement identity that created it.

  ## Technical depth

  Delegates to `Loopex.SessionDirectory.record_session/3`. A host calls this
  after `create_session/3` commits, so a later `list_sessions/1` or
  `resume_known_session/4` can find it.
  """
  @spec track_session(Path.t(), binary(), binary()) :: :ok | {:error, term()}
  def track_session(state_root, session_id, runtime_id),
    do: SessionDirectory.record_session(state_root, session_id, runtime_id)

  @doc """
  ## Concept

  Lists the sessions an operator's state root knows about.

  ## Technical depth

  Delegates to `Loopex.SessionDirectory.list_sessions/1` and reads only the
  resolved state root's files, so a fresh operating-system process with no
  runtime started yet sees the same sessions a live host would.
  """
  @spec list_sessions(Path.t()) :: {:ok, [SessionDirectory.entry()]} | {:error, term()}
  def list_sessions(state_root), do: SessionDirectory.list_sessions(state_root)

  @doc """
  ## Concept

  Resumes a session the operator's state root already knows about, enforcing
  ADR 0008 runtime placement: the supplied runtime must carry the exact
  `runtime_id` that created the session, and re-presenting a `command_id`
  already resolved here returns its historical result instead of contesting
  ownership again.

  ## Technical depth

  Delegates to `Loopex.SessionDirectory.resume/4`. A placement mismatch is
  refused before any Store call, as `{:error, {:runtime_placement_mismatch,
  reason}}` naming the runtime_id the session requires; only a fresh
  `command_id` acquires a genuine replacement owner.
  """
  @spec resume_known_session(Path.t(), Runtime.t(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def resume_known_session(state_root, runtime, session_id, command_id),
    do: SessionDirectory.resume(state_root, runtime, session_id, command_id)
end

defmodule LoopexComposition.Delegation.Helper do
  @moduledoc """
  ## Concept

  The one serial owner of a durable host's helper ledger. It admits a parent's
  `loopex.task` call, reserves its allowance, creates and prompts the child,
  and later settles the child and retains the receipt, so every helper fact
  is written once, in order, by one process.

  ## Technical depth

  ADR 0046's adapter owner. It owns the RetainedObjects ledger and is bound
  once to one runtime incarnation. Admission decides every tagged pre-effect
  refusal in ADR 0046's fixed order before a reserve append is attempted;
  after that it returns only a receipt or an untagged unresolved error. Child
  creation uses Core's exact-genesis create variant and the prompt carries the
  reservation and absolute cutoff as authored bounds. The owner never waits
  for child provider work: `execute/3` waits in the caller and returns to the
  owner only to settle. Core's ADR 0069 run evidence supplies the prompt
  digest and settlement accounting; Core's receipt validator admits receipts.
  An unresolved ledger commit fences every later mutation of this owner.
  """

  use GenServer

  alias Loopex.{Executor, Runtime}

  alias LoopexComposition.Delegation.{
    ChildCreation,
    GenesisCodec,
    LedgerCodec,
    ParentBinding,
    Receipt,
    RetainedObjects,
    RunLedger,
    RunMutation,
    Tool
  }

  alias LoopexProtocol.Canonical

  @frame 65_614
  @registry_rows 4_096
  @tombstones 4_096
  @poll_ms 20
  @text_bytes 16_384
  @order ~w(router_unavailable helper_admission_closed cancelled_before_registration job_binding_conflict router_registration_capacity helper_index_unavailable helper_classification_incomplete invalid_tool_arguments delegation_binding_unavailable unknown_role ledger_fenced helper_slot_occupied parent_cutoff_passed delegation_count_exhausted delegation_tokens_exhausted ledger_capacity)a

  @doc false
  def order, do: @order

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Bind this owner to its one runtime incarnation.

  ## Technical depth

  Identical rebinding is idempotent; a different runtime refuses. Until bound,
  every helper call refuses `router_unavailable`.
  """
  def bind(helper, runtime), do: GenServer.call(helper, {:bind, runtime}, :infinity)

  @doc false
  def classification(helper, value),
    do: GenServer.call(helper, {:classification, value}, :infinity)

  @doc false
  def status(helper), do: GenServer.call(helper, :status, :infinity)

  @doc """
  ## Concept

  Create one helper-enabled parent session from its frozen catalog.

  ## Technical depth

  The parent capture's objects sync before `prepare_parent`; Core's
  exact-genesis create variant creates the session; `bind_parent` commits
  before the session ID is returned. A repeat with the same command returns
  the original session.
  """
  def create_parent(helper, capture),
    do: GenServer.call(helper, {:create_parent, capture}, :infinity)

  @doc """
  ## Concept

  Classify one session for host routes: a helper child, a helper parent or an
  ordinary session.

  ## Technical depth

  ADR 0069's guard source. Before classification completes every session is
  unclassified and mutating routes must refuse.
  """
  def classify_session(helper, session_id),
    do: GenServer.call(helper, {:classify_session, session_id}, :infinity)

  @doc false
  def register_local(helper, job_id),
    do: GenServer.call(helper, {:register_local, job_id}, :infinity)

  @doc false
  def unregister_local(helper, job_id), do: GenServer.cast(helper, {:unregister_local, job_id})

  @doc """
  ## Concept

  Run one helper call to its receipt.

  ## Technical depth

  Admission, reserve, creation and prompt happen in the owner. The caller then
  observes the child's durable run evidence until it ends, stopping it at the
  absolute cutoff, and returns to the owner to settle and bind the receipt.
  """
  def execute(helper, job) do
    case GenServer.call(helper, {:launch, job}, :infinity) do
      {:launched, launch} -> await(helper, job, launch)
      other -> other
    end
  end

  @doc false
  def cancel(helper, job_id), do: GenServer.call(helper, {:cancel, job_id}, :infinity)

  @doc false
  def retained_receipt(helper, job_id),
    do: GenServer.call(helper, {:retained_receipt, job_id}, :infinity)

  @impl true
  def init(options) do
    {:ok,
     %{
       objects: Keyword.fetch!(options, :objects),
       runtime_id: Keyword.fetch!(options, :runtime_id),
       clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end),
       runtime: nil,
       classified: Keyword.get(options, :classified, :pending),
       parents: %{},
       children: %{},
       runs: %{},
       originals: %{},
       jobs: %{},
       receipts: %{},
       local: MapSet.new(),
       tombstones: MapSet.new(),
       closed: false,
       fenced: false,
       intents: %{},
       settlements: %{},
       blobs: %{}
     }}
  end

  @impl true
  def handle_call({:bind, runtime}, _from, %{runtime: nil} = state),
    do: {:reply, :ok, %{state | runtime: runtime}}

  def handle_call({:bind, runtime}, _from, %{runtime: runtime} = state),
    do: {:reply, :ok, state}

  def handle_call({:bind, _runtime}, _from, state),
    do: {:reply, {:error, :router_bound}, state}

  def handle_call({:classification, value}, _from, state),
    do: {:reply, :ok, %{state | classified: value}}

  def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

  def handle_call({:register_parent, session, parent}, _from, state),
    do: {:reply, :ok, %{state | parents: Map.put(state.parents, session, parent)}}

  def handle_call(:status, _from, state),
    do:
      {:reply,
       Map.take(state, [:classified, :closed, :fenced, :parents, :children, :runs, :receipts]),
       state}

  def handle_call({:create_parent, capture}, _from, state) do
    case do_create_parent(state, capture) do
      {:ok, session, state} -> {:reply, {:ok, session}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:classify_session, session}, _from, state) do
    reply =
      cond do
        state.classified != :complete -> {:error, :helper_classification_incomplete}
        Map.has_key?(state.children, session) -> {:ok, :helper_child}
        Map.has_key?(state.parents, session) -> {:ok, :helper_parent}
        true -> {:ok, :ordinary}
      end

    {:reply, reply, state}
  end

  def handle_call({:register_local, job_id}, _from, state) do
    if MapSet.size(state.local) + map_size(state.jobs) >= @registry_rows,
      do: {:reply, {:error, {:refused_before_effect, :router_registration_capacity}}, state},
      else: {:reply, :ok, %{state | local: MapSet.put(state.local, job_id)}}
  end

  def handle_call({:launch, job}, _from, state) do
    case launch(state, job) do
      {:launched, launch, state} -> {:reply, {:launched, launch}, state}
      {:refused, reason, state} -> {:reply, {:error, {:refused_before_effect, reason}}, state}
      {:unresolved, state} -> {:reply, {:error, :effect_unresolved}, state}
    end
  end

  def handle_call({:finish, job_id, observation}, _from, state) do
    case finish(state, job_id, observation) do
      {:ok, receipt, state} -> {:reply, {:ok, receipt}, state}
      {:unresolved, state} -> {:reply, {:error, :effect_unresolved}, state}
    end
  end

  def handle_call({:stop, job_id, reason}, _from, state) do
    {reply, state} = stop(state, job_id, reason)
    {:reply, reply, state}
  end

  def handle_call({:cancel, job_id}, _from, state) do
    cond do
      Map.has_key?(state.jobs, job_id) ->
        {reply, state} = stop(state, job_id, "cancel")
        {:reply, reply, state}

      MapSet.member?(state.local, job_id) ->
        {:reply, :local, state}

      MapSet.size(state.tombstones) >= @tombstones ->
        {:reply, :unknown, %{state | closed: true}}

      true ->
        {:reply, :unknown, %{state | tombstones: MapSet.put(state.tombstones, job_id)}}
    end
  end

  def handle_call({:retained_receipt, job_id}, _from, state) do
    reply =
      cond do
        Map.has_key?(state.receipts, job_id) -> {:ok, state.receipts[job_id]}
        Map.has_key?(state.jobs, job_id) -> {:error, :effect_in_flight}
        state.classified != :complete -> {:error, :helper_index_pending}
        true -> :not_helper
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:unregister_local, job_id}, state),
    do: {:noreply, %{state | local: MapSet.delete(state.local, job_id)}}

  # Concept: parent creation retains every frozen object before Core creates.
  # Technical depth: prepare, exact-genesis create and bind are each idempotent;
  # an uncertain commit fences this owner and the parent is never returned.
  defp do_create_parent(%{runtime: nil} = state, _capture),
    do: {:error, :router_unavailable, state}

  defp do_create_parent(state, capture) do
    with {:ok, _} <-
           RetainedObjects.open_binding(state.objects, capture.command, capture.object_bytes),
         {:ok, prepare} <-
           ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture)),
         {:ok, _} <- RetainedObjects.commit_binding(state.objects, capture.command, prepare),
         {:ok, session} <-
           Runtime.create_session_with_genesis(
             state.runtime,
             capture.command,
             capture.options,
             capture.genesis
           ),
         {:ok, bind} <-
           ParentBinding.transaction(
             capture.key,
             1,
             ParentBinding.bind_mutation(capture, session)
           ),
         {:ok, _} <-
           RetainedObjects.commit_binding(state.objects, capture.command, bind, state.runtime) do
      parent = %{command: capture.command, capture: capture, binding: [prepare, bind]}
      {:ok, session, %{state | parents: Map.put(state.parents, session, parent)}}
    else
      {:error, {:commit_unknown, _}} -> {:error, :ledger_fenced, %{state | fenced: true}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc false
  def register_parent(helper, session, parent),
    do: GenServer.call(helper, {:register_parent, session, parent}, :infinity)

  # Concept: refusals are decided in ADR 0046's fixed order before any append.
  # Technical depth: each check yields its reason or nil; the first non-nil
  # reason wins. Checks needing ledger state read only the in-memory fold.
  defp launch(state, job) do
    parent = Map.get(state.parents, job.session_id)
    arguments = job.validated_arguments

    role =
      parent && is_map(arguments) &&
        Enum.find(parent.capture.catalog["roles"], &(&1["name"] == arguments["role"]))

    now = state.clock.()

    checks = [
      router_unavailable: is_nil(state.runtime),
      helper_admission_closed: state.closed,
      cancelled_before_registration: MapSet.member?(state.tombstones, job.job_id),
      job_binding_conflict:
        Map.has_key?(state.jobs, job.job_id) and state.jobs[job.job_id].job != job,
      router_registration_capacity:
        MapSet.size(state.local) + map_size(state.jobs) >= @registry_rows,
      helper_index_unavailable: false,
      helper_classification_incomplete: state.classified != :complete,
      invalid_tool_arguments: Tool.validate_arguments(arguments) != :ok,
      delegation_binding_unavailable: is_nil(parent),
      unknown_role: is_nil(role) or arguments["role"] not in parent.capture.declaration["roles"],
      ledger_fenced: state.fenced,
      helper_slot_occupied: occupied?(state, job.session_id),
      parent_cutoff_passed: job.effective_job_deadline <= now
    ]

    case Enum.find(checks, fn {_reason, failed} -> failed end) do
      {reason, true} ->
        {:refused, reason, state}

      nil ->
        if Map.has_key?(state.jobs, job.job_id),
          do: {:unresolved, state},
          else: reserve(state, job, parent, now)
    end
  end

  defp occupied?(state, session) do
    Enum.any?(state.runs, fn {{parent, _run}, run} ->
      parent == session and RunLedger.occupied?(run)
    end)
  end

  defp reserve(state, job, parent, now) do
    ids = [state.runtime_id, job.session_id, job.run_id]
    declaration = parent.capture.declaration

    with {:ok, run, state} <- run_state(state, parent, ids),
         :ok <- allowance(run, declaration),
         {:ok, source, state} <- source_intent(state, job),
         operation = operation_identity(job),
         {:ok, bytes, child} <- child_creation(state, parent, job, operation, run),
         cutoff =
           min(job.effective_job_deadline, now + declaration["child_bounds"]["deadline_ms"]),
         mutation = %{
           "kind" => "reserve",
           "operation_identity" => operation,
           "source_intent" => source,
           "job" => project(job),
           "role" => job.validated_arguments["role"],
           "task_digest" => Canonical.digest(job.validated_arguments),
           "child_creation_sha256" => hash(bytes),
           "create_command_id" => Base.encode64(child.command_id),
           "prompt_command_id" => Base.encode64(child.prompt_command_id),
           "absolute_cutoff_ms" => cutoff,
           "reserved_tokens" => child.reserved_tokens,
           "closing_credit_bytes" => 5 * @frame
         },
         {:ok, tx} <- RunMutation.transaction(ids, run.version, mutation),
         {:ok, _next, _} <- RunLedger.admit(run, tx, %{original_job: job, child_creation: bytes}),
         {:ok, _hash} <- RetainedObjects.install(state.objects, bytes) do
      state = %{
        state
        | blobs: Map.put(state.blobs, hash(bytes), bytes),
          originals: Map.put(state.originals, job.job_id, job),
          jobs:
            Map.put(state.jobs, job.job_id, %{
              job: job,
              ids: ids,
              operation: operation,
              parent: parent,
              child: child
            })
      }

      case commit(state, ids, tx, %{original_job: job, child_creation: bytes}) do
        {:ok, state} -> create_child(state, job.job_id, child, cutoff)
        {:error, state} -> {:unresolved, state}
      end
    else
      {:refused, reason, state} -> {:refused, reason, state}
      {:refused, reason} -> {:refused, reason, state}
      {:error, :run_byte_limit} -> {:refused, :ledger_capacity, state}
      {:error, :delegation_count_exhausted} -> {:refused, :delegation_count_exhausted, state}
      {:error, :delegation_tokens_exhausted} -> {:refused, :delegation_tokens_exhausted, state}
      {:error, _reason} -> {:refused, :delegation_binding_unavailable, state}
    end
  end

  defp allowance(run, declaration) do
    available = declaration["token_budget"] - run.charged_tokens - run.reserved_tokens

    cond do
      run.count >= declaration["max_children"] -> {:refused, :delegation_count_exhausted}
      available <= 0 -> {:refused, :delegation_tokens_exhausted}
      run.bytes + 5 * @frame + @frame + run.credit > 16_777_216 -> {:refused, :ledger_capacity}
      true -> :ok
    end
  end

  # Concept: a parent run's log is initialized from its frozen declaration once.
  # Technical depth: a resumed run reuses its retained counters; a new run starts
  # its own allowance from the same immutable declaration.
  defp run_state(state, parent, [_runtime, session, run_id] = ids) do
    case Map.fetch(state.runs, {session, run_id}) do
      {:ok, run} ->
        {:ok, run, state}

      :error ->
        with {:ok, run} <-
               RunLedger.new(ids, parent.capture, parent.binding, history(state, parent)),
             {:ok, _key} <-
               RetainedObjects.open_run(state.objects, parent.command, ids, state.runtime),
             {:ok, tx} <- RunMutation.transaction(ids, 0, RunLedger.initialize_mutation(run)),
             {:ok, run, _} <- RunLedger.admit(run, tx),
             {:ok, _} <-
               RetainedObjects.commit_run(state.objects, parent.command, ids, tx, state.runtime) do
          {:ok, run, %{state | runs: Map.put(state.runs, {session, run_id}, run)}}
        else
          {:error, {:commit_unknown, _}} -> {:refused, :ledger_fenced, %{state | fenced: true}}
          _ -> {:refused, :delegation_binding_unavailable, state}
        end
    end
  end

  defp history(state, parent) do
    case ParentBinding.observe_creation(state.runtime, parent.capture) do
      {:ok, observed} -> observed
      _ -> :unobserved
    end
  end

  # Concept: each reservation names the exact committed intent it serves.
  # Technical depth: the parent's private history is scanned forward from this
  # owner's last verified boundary until the job's intent row is found.
  defp source_intent(state, job) do
    case Map.fetch(state.intents, job.job_id) do
      {:ok, version} ->
        {:ok, source(job, version), state}

      :error ->
        case scan_intents(state, job.session_id) do
          {:ok, state} ->
            case Map.fetch(state.intents, job.job_id) do
              {:ok, version} -> {:ok, source(job, version), state}
              :error -> {:refused, :helper_index_unavailable, state}
            end

          :error ->
            {:refused, :helper_index_unavailable, state}
        end
    end
  end

  defp source(job, version),
    do: %{
      "session_id" => Base.encode64(job.session_id),
      "journal_version" => version,
      "canonical_request_digest" => job.canonical_request_digest
    }

  @doc false
  def scan_intents(state, session), do: scan_intents(state, session, nil)

  defp scan_intents(state, session, cursor) do
    case Runtime.effect_intents(state.runtime, session, cursor, 16) do
      {:ok, page} ->
        intents =
          Enum.reduce(page.rows, state.intents, fn
            %{kind: "intent", journal_version: version, job: job}, acc ->
              Map.put(acc, job.job_id, version)

            _row, acc ->
              acc
          end)

        state = %{state | intents: intents}

        if page.next_cursor,
          do: scan_intents(state, session, page.next_cursor),
          else: {:ok, state}

      _ ->
        :error
    end
  end

  defp child_creation(state, parent, job, operation, run) do
    declaration = parent.capture.declaration
    available = declaration["token_budget"] - run.charged_tokens - run.reserved_tokens
    reserved = min(declaration["child_bounds"]["token_budget"], available)

    role =
      Enum.find(parent.capture.catalog["roles"], &(&1["name"] == job.validated_arguments["role"]))

    options = parent.capture.options
    create = command("loopex:helper-create:v1", state.runtime_id, operation)

    with {:ok, selected} <- GenesisCodec.decode(role["genesis"]),
         genesis = Map.put(selected, "options", options),
         {:ok, retained} <- GenesisCodec.encode(genesis),
         {:ok, transaction} <- Loopex.Store.create_session(state.runtime_id, create, genesis),
         options_bytes = :erlang.term_to_binary(options, [:deterministic]),
         object = %{
           "version" => 1,
           "kind" => "child_creation",
           "runtime_id" => Base.encode64(state.runtime_id),
           "operation_identity" => operation,
           "role" => role["name"],
           "catalog_sha256" => parent.capture.creation["catalog_sha256"],
           "declaration_sha256" => parent.capture.creation["declaration_sha256"],
           "command_id" => Base.encode64(create),
           "original_options" => %{
             "encoding" => "loopex.ledger.plain_etf.v1.base64",
             "bytes" => Base.encode64(options_bytes),
             "sha256" => hash(options_bytes)
           },
           "genesis" => retained,
           "canonical_create_digest" =>
             Base.encode16(transaction.canonical_mutation_digest, case: :lower)
         },
         {:ok, input} <- domain("loopex:helper-create-input:v1", object),
         {:ok, bytes} <-
           LedgerCodec.encode_json(Map.put(object, "input_digest", input), :object),
         {:ok, child} <- ChildCreation.validate(bytes, capture_of(parent), reserved) do
      {:ok, bytes, child}
    else
      _ -> {:refused, :delegation_binding_unavailable}
    end
  end

  defp capture_of(parent),
    do: %{
      runtime: parent.capture.runtime,
      command: parent.capture.command,
      object_bytes: parent.capture.object_bytes
    }

  # Concept: the child is created with its exact retained genesis, then prompted
  # once with the reservation and cutoff as authored bounds.
  # Technical depth: both commands use derived logical IDs, so a repeat cannot
  # allocate a second child. Each known result commits before the next step.
  defp create_child(state, job_id, child, cutoff) do
    entry = state.jobs[job_id]

    with {:ok, session} <-
           Runtime.create_session_with_genesis(
             state.runtime,
             child.command_id,
             child.options,
             child.genesis
           ),
         {:ok, state} <- created(state, entry, session),
         {:ok, attachment} <- Runtime.attach(state.runtime, session, after_event_sequence: 0),
         {:accepted, _} <-
           Runtime.command(attachment, %{
             type: :prompt,
             command_id: child.prompt_command_id,
             content: entry.job.validated_arguments["prompt"],
             bounds: %{
               max_turns: child.declaration["child_bounds"]["max_turns"],
               token_budget: child.reserved_tokens,
               deadline_at_ms: cutoff
             }
           }),
         {:ok, %{run_id: run}} <- disposition(attachment, child.prompt_command_id),
         {:ok, evidence} <- Runtime.run_evidence(state.runtime, session, run),
         {:ok, state} <- prompted(state, entry, session, run, evidence.admission.digest) do
      {:launched,
       %{session: session, run: run, cutoff: cutoff, grace: entry.job.cleanup_grace_ms}, state}
    else
      {:unresolved, state} -> {:unresolved, state}
      _ -> {:unresolved, state}
    end
  end

  defp disposition(attachment, command) do
    case Runtime.command_disposition(attachment, command) do
      {:ok, {:committed, :admitted, _code, run}} when is_binary(run) -> {:ok, %{run_id: run}}
      other -> {:error, other}
    end
  end

  defp created(state, entry, session) do
    run = state.runs[{Enum.at(entry.ids, 1), Enum.at(entry.ids, 2)}]
    {:ok, object} = LedgerCodec.decode_json(run.operation.child_creation, :object)
    {:ok, genesis} = GenesisCodec.decode(object["genesis"])

    mutation = %{
      "kind" => "child_created",
      "operation_identity" => entry.operation,
      "child_session_id" => Base.encode64(session),
      "child_creation_sha256" => run.operation.logical["child_creation_sha256"],
      "configuration_digest" => Canonical.digest(genesis["initial_configuration"]),
      "tool_selection_sha256" => Canonical.digest(genesis["tool_selection"]),
      "policy_defer_mode" => "refuse"
    }

    state = %{state | children: Map.put(state.children, session, entry.job.job_id)}
    append(state, entry.ids, mutation, %{})
  end

  defp prompted(state, entry, session, run, digest) do
    mutation = %{
      "kind" => "child_prompted",
      "operation_identity" => entry.operation,
      "child_session_id" => Base.encode64(session),
      "child_run_id" => Base.encode64(run),
      "prompt_command_id" => Base.encode64(entry.child.prompt_command_id),
      "prompt_digest" => digest
    }

    append(state, entry.ids, mutation, %{prompt_digest: digest})
  end

  defp append(state, ids, mutation, inputs) do
    run = state.runs[{Enum.at(ids, 1), Enum.at(ids, 2)}]

    with {:ok, tx} <- RunMutation.transaction(ids, run.version, mutation),
         {:ok, _, _} <- RunLedger.admit(run, tx, inputs),
         {:ok, state} <- commit(state, ids, tx, inputs) do
      {:ok, state}
    else
      {:error, %{} = state} -> {:unresolved, state}
      _ -> {:unresolved, state}
    end
  end

  # Concept: append once, then fold the same transaction into the live view.
  # Technical depth: an uncertain append fences the whole owner; the in-memory
  # fold advances only after the durable acknowledgement.
  defp commit(state, [_runtime, session, run_id] = ids, tx, inputs) do
    parent = state.parents[session]
    run = state.runs[{session, run_id}]
    replay = &replay_inputs(state, &1)

    case RetainedObjects.commit_run(state.objects, parent.command, ids, tx, state.runtime,
           inputs: inputs,
           replay: replay
         ) do
      {:ok, _result} ->
        {:ok, next, _} = RunLedger.admit(run, tx, inputs)
        {:ok, %{state | runs: Map.put(state.runs, {session, run_id}, next)}}

      {:error, {:commit_unknown, _}} ->
        {:error, %{state | fenced: true}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  # Concept: replay rejoins each frame to evidence this owner already validated.
  defp replay_inputs(state, %{"mutation" => mutation} = _tx) do
    case mutation["kind"] do
      kind when kind in ~w(reserve stop) ->
        job_id = Base.decode64!(mutation["job"]["job_id"])
        original = state.originals[job_id]

        if kind == "reserve" do
          %{
            original_job: original,
            child_creation: state.blobs[mutation["child_creation_sha256"]]
          }
        else
          %{original_job: original}
        end

      "child_prompted" ->
        %{prompt_digest: mutation["prompt_digest"]}

      "settle" ->
        Map.get(state.settlements, mutation["operation_identity"], %{})

      "bind_receipt" ->
        job_id = Base.decode64!(mutation["job"]["job_id"])
        %{receipt: state.blobs[mutation["receipt_sha256"]], original_job: state.originals[job_id]}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  # Concept: the caller observes the child, never the owner.
  # Technical depth: durable run evidence is polled until a terminal exists.
  # At the absolute cutoff the owner commits the write-once stop and aborts the
  # child; the wait then continues for the original cleanup grace only.
  defp await(helper, job, launch) do
    runtime = GenServer.call(helper, :runtime, :infinity)
    deadline = launch.cutoff + launch.grace

    observation = observe(helper, runtime, job, launch, deadline, false)
    GenServer.call(helper, {:finish, job.job_id, observation}, :infinity)
  end

  defp observe(helper, runtime, job, launch, deadline, stopped) do
    case Runtime.run_evidence(runtime, launch.session, launch.run) do
      {:ok, %{terminal: %{}} = evidence} ->
        {:ended, evidence}

      _other ->
        now = System.system_time(:millisecond)

        cond do
          now >= deadline ->
            :unresolved

          not stopped and now >= launch.cutoff ->
            _ = GenServer.call(helper, {:stop, job.job_id, "cutoff"}, :infinity)
            observe(helper, runtime, job, launch, deadline, true)

          true ->
            Process.sleep(@poll_ms)
            observe(helper, runtime, job, launch, deadline, stopped)
        end
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def handle_runtime(state), do: state.runtime

  # Concept: settlement joins Core's own evidence and the captured history token.
  # Technical depth: the child's complete private prefix is scanned to its head;
  # if the head moved after the evidence, evidence is read again. The receipt is
  # built and validated by Core before its object installs and binds.
  defp finish(state, job_id, observation) do
    entry = state.jobs[job_id]

    with {:ended, evidence} <- observation,
         [_, session, run_id] = entry.ids,
         run = state.runs[{session, run_id}],
         child = run.operation.child && Base.decode64!(run.operation.child),
         {:ok, evidence, token} <- captured(state, child, evidence),
         {:ok, state} <- settle(state, entry, run, evidence, token),
         {:ok, receipt, state} <- bind_receipt(state, entry, evidence) do
      {:ok, receipt, state}
    else
      _ -> {:unresolved, state}
    end
  end

  defp captured(state, child, evidence) do
    with {:ok, through, token} <- prefix(state, child) do
      if through == evidence.through_version do
        {:ok, evidence, token}
      else
        run = evidence_run(state, child)

        case run && Runtime.run_evidence(state.runtime, child, run) do
          {:ok, %{through_version: ^through} = current} -> {:ok, current, token}
          _ -> :error
        end
      end
    end
  end

  defp evidence_run(state, child) do
    Enum.find_value(state.runs, fn {_key, run} ->
      run.operation && run.operation.child == Base.encode64(child) && run.operation.child_run &&
        Base.decode64!(run.operation.child_run)
    end)
  end

  @doc false
  def prefix(state, session), do: prefix(state, session, nil, nil)

  defp prefix(state, session, cursor, last) do
    case Runtime.effect_intents(state.runtime, session, cursor, 16) do
      {:ok, %{next_cursor: nil} = page} -> {:ok, page.scanned_through, page.prefix_token}
      {:ok, page} -> prefix(state, session, page.next_cursor, page)
      _ -> if(last, do: :error, else: :error)
    end
  end

  defp settle(state, entry, run, evidence, token) do
    reserved = run.operation.logical["reserved_tokens"]
    usage = evidence.usage
    total = usage.reported_input + usage.reported_output + usage.estimated
    charge = if usage.unresolved, do: max(reserved, total), else: total

    terminal = %{
      "state" => evidence.terminal.state,
      "child_session_id" => run.operation.child,
      "child_run_id" => run.operation.child_run,
      "journal_version" => evidence.terminal.journal_version,
      "terminal_record_sha256" => evidence.terminal.record_digest,
      "cleanup" => "confirmed"
    }

    accounting = %{
      "reported_input_tokens" => usage.reported_input,
      "reported_output_tokens" => usage.reported_output,
      "estimated_tokens" => usage.estimated,
      "unresolved_usage" => usage.unresolved,
      "charged_tokens" => charge,
      "through_version" => evidence.through_version,
      "prefix_token" => Base.encode64(token)
    }

    with true <- evidence.terminal.state in ~w(completed failed cancelled bound_reached),
         {:ok, digest} <-
           domain_value("loopex:helper-accounting-evidence:v1", [
             entry.operation,
             terminal,
             accounting
           ]) do
      mutation = %{
        "kind" => "settle",
        "operation_identity" => entry.operation,
        "terminal" => terminal,
        "accounting" => Map.put(accounting, "evidence_sha256", digest),
        "charge_tokens" => charge,
        "refund_tokens" => max(0, reserved - charge)
      }

      inputs = %{evidence: evidence, prefix_token: token}
      state = %{state | settlements: Map.put(state.settlements, entry.operation, inputs)}
      append(state, entry.ids, mutation, inputs)
    else
      _ -> {:unresolved, state}
    end
  end

  defp bind_receipt(state, entry, evidence) do
    [_, session, run_id] = entry.ids
    run = state.runs[{session, run_id}]
    stopped = run.operation && run.operation.stop != nil
    {outcome, output} = result(state, entry, run, evidence, stopped)

    with {:ok, receipt} <-
           Receipt.build(entry.job, outcome, output, :confirmed, System.system_time(:millisecond)),
         {:ok, bytes} <-
           Receipt.object(state.runtime_id, entry.operation, project(entry.job), receipt),
         {:ok, _} <- RetainedObjects.install(state.objects, bytes),
         state = %{state | blobs: Map.put(state.blobs, hash(bytes), bytes)},
         mutation = %{
           "kind" => "bind_receipt",
           "operation_identity" => entry.operation,
           "job" => project(entry.job),
           "receipt_sha256" => hash(bytes)
         },
         {:ok, state} <-
           append(state, entry.ids, mutation, %{receipt: bytes, original_job: entry.job}) do
      state = %{
        state
        | receipts: Map.put(state.receipts, entry.job.job_id, receipt),
          jobs: Map.delete(state.jobs, entry.job.job_id)
      }

      {:ok, receipt, state}
    else
      _ -> {:unresolved, state}
    end
  end

  # Concept: the model sees bounded child text plus the evidence trailer.
  # Technical depth: up to 16 KiB of the child's final assistant text with an
  # explicit truncation flag; usage reports the child charge, the delegation
  # totals and the parent run's own usage separately and combined.
  defp result(state, entry, run_before_release, evidence, stopped) do
    text = final_text(state, evidence, run_before_release)
    truncated = byte_size(text) > @text_bytes
    text = if truncated, do: truncate(text, @text_bytes), else: text
    [_, parent_session, parent_run] = entry.ids
    run = state.runs[{parent_session, parent_run}]
    parent_usage = parent_usage(state, parent_session, parent_run)
    child_usage = evidence.usage
    child_total = child_usage.reported_input + child_usage.reported_output + child_usage.estimated

    outcome =
      case evidence.terminal.state do
        "completed" -> :completed
        "cancelled" when stopped -> :cancelled
        _ -> :failed
      end

    {:ok, output} =
      LedgerCodec.encode_json(
        %{
          "role" => entry.job.validated_arguments["role"],
          "catalog_sha256" => entry.parent.capture.creation["catalog_sha256"],
          "model" => entry.child.genesis["initial_configuration"]["model"],
          "child_session_id" => run_child(run_before_release),
          "outcome" => evidence.terminal.state,
          "text" => text,
          "truncated" => truncated,
          "usage" => %{
            "child" => %{
              "reported_input_tokens" => child_usage.reported_input,
              "reported_output_tokens" => child_usage.reported_output,
              "estimated_tokens" => child_usage.estimated,
              "unresolved" => child_usage.unresolved
            },
            "delegation" => %{
              "charged_tokens" => run.charged_tokens,
              "reserved_tokens" => run.reserved_tokens,
              "children" => run.count
            },
            "parent" => parent_usage,
            "combined_tokens" => parent_usage["tokens"] + child_total
          }
        },
        :object
      )

    {outcome, output}
  end

  defp run_child(run), do: Base.decode64!(run.operation.child)

  defp parent_usage(state, session, run) do
    case Runtime.run_evidence(state.runtime, session, run) do
      {:ok, %{usage: usage}} ->
        %{
          "reported_input_tokens" => usage.reported_input,
          "reported_output_tokens" => usage.reported_output,
          "estimated_tokens" => usage.estimated,
          "tokens" => usage.reported_input + usage.reported_output + usage.estimated
        }

      _ ->
        %{"tokens" => 0}
    end
  end

  defp final_text(state, evidence, run) do
    child = Base.decode64!(run.operation.child)
    child_run = Base.decode64!(run.operation.child_run)

    with true <- evidence.terminal != nil,
         {:ok, attachment} <- Runtime.attach(state.runtime, child, after_event_sequence: 0) do
      drain(attachment, child_run, "")
    else
      _ -> ""
    end
  end

  defp drain(attachment, run, text) do
    case Runtime.next_event(attachment) do
      {:ok, %{kind: "assistant.message_appended"} = event} ->
        drain(
          attachment,
          run,
          if(event["run_id"] == run, do: event["content"] || text, else: text)
        )

      {:ok, _event} ->
        drain(attachment, run, text)

      _ ->
        text
    end
  end

  defp truncate(text, limit) do
    text
    |> binary_part(0, limit)
    |> String.chunk(:valid)
    |> Enum.take_while(&String.valid?/1)
    |> Enum.join()
  end

  # Concept: the first stop wins and excludes every later launch.
  # Technical depth: the owner commits the write-once stop, then asks Core to
  # abort the child's run; cleanup is observed by the waiting caller, never here.
  defp stop(state, job_id, reason) do
    with %{} = entry <- state.jobs[job_id],
         [_, session, run_id] = entry.ids,
         %{operation: %{} = operation} <- state.runs[{session, run_id}] do
      state =
        if operation.stop == nil do
          case commit_stop(state, entry, reason) do
            {:ok, state} ->
              abort_child(state, operation)
              state

            {:unresolved, state} ->
              state
          end
        else
          state
        end

      {observation(state, operation, entry.job), state}
    else
      _ -> {{:ok, :unconfirmed}, state}
    end
  end

  # Concept: cleanup is observed by the canceller within the parent's bound.
  # Technical depth: the reply names the child run for the caller to observe;
  # the owner never waits for cleanup itself.
  defp observation(state, %{child: child, child_run: run}, job)
       when is_binary(child) and is_binary(run) do
    {:stopped,
     %{
       runtime: state.runtime,
       session: Base.decode64!(child),
       run: Base.decode64!(run),
       grace: job.cleanup_grace_ms
     }}
  end

  defp observation(_state, _operation, _job), do: {:ok, :unconfirmed}

  defp commit_stop(state, entry, reason) do
    with {:ok, key} <- LedgerCodec.header_key(:run, entry.ids),
         {:ok, stop_id} <- domain_value("loopex:helper-tx:v1", [key, "stop", entry.operation]) do
      append(
        state,
        entry.ids,
        %{
          "kind" => "stop",
          "operation_identity" => entry.operation,
          "job" => project(entry.job),
          "stop_tx_id" => stop_id,
          "reason" => reason
        },
        %{original_job: entry.job}
      )
    else
      _ -> {:unresolved, state}
    end
  end

  defp abort_child(state, %{child: child, child_run: run})
       when is_binary(child) and is_binary(run) do
    session = Base.decode64!(child)

    with {:ok, attachment} <- Runtime.attach(state.runtime, session, after_event_sequence: 0) do
      Runtime.command(attachment, %{
        type: :abort,
        command_id: "helper-abort:" <> Base.decode64!(run),
        run_id: Base.decode64!(run)
      })
    end
  end

  defp abort_child(_state, _operation), do: :ok

  defp operation_identity(job),
    do: %{
      "parent_session_id" => Base.encode64(job.session_id),
      "parent_run_id" => Base.encode64(job.run_id),
      "operation_id" => Base.encode64(job.operation_id)
    }

  @doc false
  def project(job),
    do: %{
      "job_id" => Base.encode64(job.job_id),
      "route" => "helper",
      "operation_id" => Base.encode64(job.operation_id),
      "attempt" => job.attempt,
      "session_id" => Base.encode64(job.session_id),
      "run_id" => Base.encode64(job.run_id),
      "canonical_request_digest" => job.canonical_request_digest,
      "origin_session_epoch" => job.origin_session_epoch,
      "origin_executor_epoch" => job.origin_executor_epoch,
      "executor_identity" => Base.encode64(job.executor_identity),
      "fencing_token" => job.fencing_token,
      "cleanup_grace_ms" => job.cleanup_grace_ms
    }

  defp command(label, runtime, operation) do
    {:ok, id} = domain_value(label, [Base.encode64(runtime), operation])
    id
  end

  defp domain(label, object),
    do: domain_value(label, Map.drop(object, ~w(input_digest canonical_create_digest)))

  defp domain_value(label, value) do
    with {:ok, wrapped} <- LedgerCodec.encode_json(%{"v" => value}, :object) do
      bytes = binary_part(wrapped, 5, byte_size(wrapped) - 6)
      {:ok, hash(label <> <<0>> <> bytes)}
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc false
  def executor_valid?(job), do: Executor.validate_job(job) == :ok
end

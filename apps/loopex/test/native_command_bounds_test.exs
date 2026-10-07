Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.NativeCommandBoundsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime.SessionState
  alias Loopex.AgentLoopTestExecutor

  defmodule BoundsArtifactStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start(options \\ []) do
      Agent.start_link(fn ->
        %{
          objects: %{},
          uses: %{},
          observer: options[:observer],
          gate: options[:gate],
          failure: options[:failure]
        }
      end)
    end

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      settings = Agent.get(pid, &Map.take(&1, [:observer, :gate, :failure]))

      if is_pid(settings.observer),
        do: send(settings.observer, {:artifact_put, self(), bytes, metadata})

      if settings.gate == :hold do
        receive do
          :retain_source -> :ok
        end
      end

      case settings.failure do
        :raise -> raise "private artifact adapter failure"
        :throw -> throw({:private_adapter_failure, bytes})
        :exit -> exit({:private_adapter_failure, metadata})
        nil -> retain(pid, bytes, media_type, role, metadata)
      end
    end

    def put(_pid, _bytes, _use), do: {:error, :adapter_received_unnormalized_use}

    defp retain(pid, bytes, media_type, role, metadata) do
      digest = Canonical.digest_bytes(bytes)
      object = %{digest: digest, size: byte_size(bytes), locator: "runtime:" <> digest}

      artifact_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", artifact_use])

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
            uses: Map.put(state.uses, reference.use_locator, artifact_use)
        }
      end)

      {:ok, reference}
    end

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_stored, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def describe(pid, use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, artifact_use} -> {:ok, artifact_use}
        :error -> {:error, :unknown_artifact_use}
      end
    end
  end

  defp state do
    %SessionState{
      session_id: "native-authored-bounds",
      configuration: ConfiguredGenesisFixture.configuration(),
      tool_selection: %{"definitions" => [], "names" => %{}}
    }
  end

  defp resolved(overrides \\ %{}) do
    Map.merge(
      %{
        max_turns: 8,
        token_budget: 100_000,
        deadline_ms: 60_000,
        context_token_budget: 8_192,
        admitted_at: 1
      },
      overrides
    )
  end

  defp prompt(id, extra \\ %{}),
    do: Map.merge(%{type: :prompt, command_id: id, content: "implement"}, extra)

  defp admitted(command, defaults \\ resolved()) do
    assert {:ok, proposal} = SessionState.propose(state(), command, defaults)
    assert proposal.reply == {:accepted, command.command_id}
    proposal.next
  end

  defp finish_before_staging(state) do
    run = state.active_run_id
    {declared, _} = SessionState.accounting(state, run)
    ceiling = declared.deadline_at_ms

    assert {:ok, proposal} =
             SessionState.propose_run_terminal(state, run, "bound_reached", %{
               bound: "deadline",
               observed: ceiling,
               declared_limit: ceiling,
               accounting_source: nil
             })

    proposal.next
  end

  defp fixture(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    {fixture, session, attachment}
  end

  defp terminal(attachment, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(5)
        terminal(attachment, cutoff)
    end
  end

  test "omission and an explicit empty declaration have distinct retained identities" do
    omitted = admitted(prompt("same"))
    assert {:replayed, {:accepted, "same"}} = SessionState.propose(omitted, prompt("same"), %{})

    assert {:error, :idempotency_conflict} =
             SessionState.propose(omitted, prompt("same", %{bounds: %{}}), resolved())

    explicit = admitted(prompt("empty", %{bounds: %{}}))

    assert {:replayed, {:accepted, "empty"}} =
             SessionState.propose(explicit, prompt("empty", %{bounds: %{}}), %{})

    assert {:error, :idempotency_conflict} =
             SessionState.propose(explicit, prompt("empty"), resolved())
  end

  test "partial authored overrides retain exact selected fields before later defaults" do
    command = prompt("partial", %{bounds: %{"max_turns" => 3, "deadline_at_ms" => 2_000}})
    assert {:ok, proposal} = SessionState.propose(state(), command, resolved(%{max_turns: 3}))
    [record] = proposal.records
    assert record["command_revision"] == 2
    assert record["authored_bounds"] == %{"max_turns" => 3, "deadline_at_ms" => 2_000}
    assert record["max_turns"] == 3
    assert record["token_budget"] == 100_000

    assert {:replayed, {:accepted, "partial"}} =
             SessionState.propose(
               proposal.next,
               command,
               resolved(%{max_turns: 99, token_budget: 1})
             )

    assert {:error, :idempotency_conflict} =
             SessionState.propose(
               proposal.next,
               prompt("partial", %{bounds: %{max_turns: 4, deadline_at_ms: 2_000}}),
               resolved()
             )
  end

  test "native grammar refuses malformed, duplicate and unknown bounds without admission" do
    for bounds <- [
          nil,
          [],
          %{max_turns: 0},
          %{token_budget: -1},
          %{deadline_ms: 0},
          %{deadline_ms: 18_446_744_073_709_551_616},
          %{deadline_at_ms: 0},
          %{deadline_at_ms: 9_007_199_254_740_992},
          %{deadline_at_ms: "2000"},
          %{unknown: 1},
          %{"max_turns" => 2, max_turns: 2}
        ] do
      assert {:error, :invalid_command} =
               SessionState.propose(state(), prompt("invalid", %{bounds: bounds}), resolved())
    end

    assert {:error, :invalid_command} =
             SessionState.propose(
               state(),
               Map.put(prompt("duplicate"), "command_id", "duplicate"),
               resolved()
             )

    assert {:error, :invalid_command} =
             SessionState.propose(state(), prompt("unknown", %{host_setting: true}), resolved())
  end

  test "arbitrary precision authored limits cannot inflate a compact retained refusal" do
    huge = Integer.pow(2, 600_000)
    command = prompt("huge", %{bounds: %{max_turns: huge}})
    assert {:ok, too_large} = SessionState.propose(state(), command, resolved(%{max_turns: huge}))
    assert {:error, {:command_admission_too_large, _, _, _, 65_536}} = too_large.reply
    active = admitted(prompt("first"))
    assert {:ok, refused} = SessionState.propose(active, command, resolved())
    assert refused.reply == {:error, :run_active}
    expired_command = prompt("huge-expired", %{bounds: %{max_turns: huge, deadline_at_ms: 1}})

    assert {:ok, expired} =
             SessionState.propose(state(), expired_command, resolved(%{admitted_at: 1}))

    assert expired.reply == {:error, :deadline_elapsed}

    for proposal <- [too_large, refused, expired] do
      [record] = proposal.records
      refute Map.has_key?(record, "authored_bounds")
      assert record["command_revision"] == 2
      assert {:ok, _, bytes} = Loopex.Store.normalize_and_measure_item(:record, record)
      assert bytes <= 65_536
    end

    assert {:replayed, {:error, :run_active}} = SessionState.propose(refused.next, command, %{})
  end

  test "fresh equal or elapsed ceilings retain one refusal without a run or events" do
    for now <- [2_000, 2_001] do
      command = prompt("expired-#{now}", %{bounds: %{deadline_at_ms: 2_000}})

      assert {:ok, proposal} =
               SessionState.propose(state(), command, resolved(%{admitted_at: now}))

      assert proposal.reply == {:error, :deadline_elapsed}
      assert proposal.events == []
      assert proposal.next.active_run_id == nil
      assert proposal.next.pending_work == %{}

      assert {:replayed, {:error, :deadline_elapsed}} =
               SessionState.propose(proposal.next, command, resolved(%{admitted_at: 1}))
    end
  end

  test "refused prompt identity retains authored limits while a run is active" do
    active = admitted(prompt("first"))
    command = prompt("refused", %{bounds: %{token_budget: 10}})
    assert {:ok, proposal} = SessionState.propose(active, command, resolved())
    assert proposal.reply == {:error, :run_active}
    assert {:replayed, {:error, :run_active}} = SessionState.propose(proposal.next, command, %{})

    assert {:error, :idempotency_conflict} =
             SessionState.propose(
               proposal.next,
               prompt("refused", %{bounds: %{token_budget: 11}}),
               resolved()
             )
  end

  test "follow-up accepts only its own ceiling and steer accepts no bounds" do
    active = admitted(prompt("first"))

    for bounds <- [%{deadline_ms: 10}, %{max_turns: 1}, %{token_budget: 1}, nil] do
      assert {:error, :invalid_command} =
               SessionState.propose(
                 active,
                 %{type: :follow_up, command_id: "follow", content: "next", bounds: bounds},
                 resolved()
               )
    end

    assert {:error, :invalid_command} =
             SessionState.propose(
               active,
               %{
                 type: :steer,
                 command_id: "steer",
                 run_id: active.active_run_id,
                 content: "redirect",
                 bounds: %{}
               },
               resolved()
             )
  end

  test "promotion inherits ordinary limits and retains the follow-up ceiling independently" do
    active = admitted(prompt("first", %{bounds: %{deadline_at_ms: 1_000}}))

    follow = %{
      type: :follow_up,
      command_id: "follow",
      content: "next",
      bounds: %{deadline_at_ms: 2_000}
    }

    assert {:ok, queued} = SessionState.propose(active, follow, resolved(%{max_turns: 99}))
    promoted = finish_before_staging(queued.next)
    {declared, _} = SessionState.accounting(promoted, promoted.active_run_id)
    assert declared.max_turns == 8
    assert declared.token_budget == 100_000
    assert declared.deadline_ms == 60_000
    assert declared.deadline_at_ms == 2_000
    assert declared.deadline == nil
    assert {:replayed, {:accepted, "follow"}} = SessionState.propose(promoted, follow, %{})
  end

  test "an omitted follow-up ceiling never inherits the predecessor absolute ceiling" do
    active = admitted(prompt("first", %{bounds: %{deadline_at_ms: 1_000}}))
    follow = %{type: :follow_up, command_id: "follow", content: "next"}
    assert {:ok, queued} = SessionState.propose(active, follow, resolved())
    promoted = finish_before_staging(queued.next)
    {declared, _} = SessionState.accounting(promoted, promoted.active_run_id)
    refute Map.has_key?(declared, :deadline_at_ms)
    assert declared.deadline_ms == 60_000
  end

  test "an accepted follow-up that expires before promotion keeps admission and ends without staging" do
    active = admitted(prompt("first", %{bounds: %{deadline_at_ms: 2_000}}))

    follow = %{
      type: :follow_up,
      command_id: "follow",
      content: "next",
      bounds: %{deadline_at_ms: 1_000}
    }

    assert {:ok, queued} = SessionState.propose(active, follow, resolved())
    promoted = finish_before_staging(queued.next)
    ended = finish_before_staging(promoted)
    assert ended.active_run_id == nil

    assert {:replayed, {:accepted, "follow"}} =
             SessionState.propose(ended, follow, resolved(%{admitted_at: 9_000}))
  end

  test "actual staged requests use the earlier authored ceiling or relative cutoff" do
    for {relative, ceiling_delta} <- [{60_000, 10_000}, {5_000, 60_000}] do
      {fixture, session, attachment} = fixture(script: [%{text: "done"}])
      before = System.system_time(:millisecond)
      ceiling = before + ceiling_delta
      command = prompt("actual", %{bounds: %{deadline_ms: relative, deadline_at_ms: ceiling}})
      assert {:accepted, "actual"} = Loopex.command(attachment, command)
      assert terminal(attachment)["outcome"] == "completed"
      [request] = AgentLoopTestModel.dispatched(fixture.model)
      assert request.deadline <= ceiling

      if relative > ceiling_delta,
        do: assert(request.deadline == ceiling),
        else: assert(request.deadline >= before + relative and request.deadline < ceiling)

      assert {:ok, recovered} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      assert {:replayed, {:accepted, "actual"}} = SessionState.propose(recovered, command, %{})

      # Concept: only the current plain representation survives recovery.
      # Technical depth: mutate the actual Store-returned admission without
      # changing its digest. Atom aliases, duplicate representations, unknown
      # keys, invalid quantities and a valid-but-different preimage all refuse.
      for authored <- [
            %{deadline_ms: relative, deadline_at_ms: ceiling},
            %{"deadline_ms" => relative, "deadline_at_ms" => ceiling, deadline_ms: relative},
            %{"deadline_ms" => relative, "deadline_at_ms" => ceiling, "unknown" => 1},
            %{"deadline_ms" => relative, "deadline_at_ms" => nil},
            %{"deadline_ms" => relative + 1, "deadline_at_ms" => ceiling}
          ] do
        tampered =
          Enum.map(Fixture.records(fixture, session), fn record ->
            if record.payload["command_id"] == "actual" and
                 record.payload.kind == "prompt_admitted_v3" do
              %{record | payload: Map.put(record.payload, "authored_bounds", authored)}
            else
              record
            end
          end)

        assert {:error, :invalid_authored_command_bounds} =
                 SessionState.recover(session, tampered, Fixture.events(fixture, session))
      end
    end
  end

  test "native replay precedes resolving changed owner defaults and does not write again" do
    {fixture, session, attachment} = fixture(script: [%{text: "done"}])
    command = prompt("retained", %{bounds: %{max_turns: 3}})
    assert {:accepted, "retained"} = Loopex.command(attachment, command)
    assert terminal(attachment)["outcome"] == "completed"
    {:ok, %{sessions: sessions}} = Loopex.Runtime.children(fixture.runtime)
    [{_, owner, _, _}] = DynamicSupervisor.which_children(sessions)
    before = Fixture.records(fixture, session)

    :sys.replace_state(owner, fn state ->
      %{state | bounds: %{max_turns: 0, token_budget: 0, deadline_ms: nil}}
    end)

    assert {:accepted, "retained"} = Loopex.command(attachment, command)

    assert {:error, :idempotency_conflict} =
             Loopex.command(
               attachment,
               prompt("retained", %{bounds: %{max_turns: 4}})
             )

    assert Fixture.records(fixture, session) == before
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "actual expired admission replays its refusal after owner recovery without dispatch" do
    {fixture, session, attachment} = fixture(script: [%{text: "must not dispatch"}])
    command = prompt("expired", %{bounds: %{deadline_at_ms: 1}})
    assert {:error, :deadline_elapsed} = Loopex.command(attachment, command)

    assert {:ok, {:committed, :refused, :deadline_elapsed, nil}} =
             Loopex.command_disposition(attachment, "expired")

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert {:replayed, {:error, :deadline_elapsed}} =
             SessionState.propose(recovered, command, %{})

    assert AgentLoopTestModel.dispatched(fixture.model) == []
  end

  # Concept: recovery starts spending both ceilings before a holder activates.
  # Technical depth: pause native scheduling through private owner state, admit
  # actual commands, and recover them through the public prepared-resume path.
  # The test never changes System UTC. A spent live allowance models rollback
  # while the retained wall ceiling remains strictly in the future.
  test "prepared recovery captures the active ceiling before delayed activation" do
    {fixture, session, attachment} = fixture(script: [%{text: "must not dispatch"}])
    original = owner(fixture)
    :sys.replace_state(original, &%{&1 | model: nil})
    ceiling = System.system_time(:millisecond) + 60_000
    command = prompt("recovered-active", %{bounds: %{deadline_at_ms: ceiling}})
    assert {:accepted, "recovered-active"} = Loopex.command(attachment, command)

    assert {:ok, {:prepared, activation}} =
             Loopex.prepare_resume_session(fixture.runtime, session, "prepared-active")

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    recovered = owner(fixture)
    state = :sys.get_state(recovered)
    run = state.durable.active_run_id
    assert is_integer(state.deadline_allowances[run])
    assert state.deadline_allowances[run] > System.monotonic_time(:millisecond)
    assert state.prepared.state == :prepared
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    :sys.replace_state(recovered, fn state ->
      %{state | deadline_allowances: %{run => System.monotonic_time(:millisecond) - 1}}
    end)

    assert System.system_time(:millisecond) < ceiling
    assert {:ok, ^session} = Loopex.activate_resume(activation)
    finished = terminal(attachment)
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    assert finished["observed"] == ceiling
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "model_request_committed_v2")
           )

    assert {:accepted, "recovered-active"} = Loopex.command(attachment, command)
  end

  test "recovery captures queued own ceiling before promotion and never refreshes its spent allowance" do
    {fixture, session, attachment} = fixture(script: [%{text: "must not dispatch either run"}])
    :sys.replace_state(owner(fixture), &%{&1 | model: nil})
    active_ceiling = System.system_time(:millisecond) + 60_000
    queued_ceiling = active_ceiling + 10_000

    assert {:accepted, "recovered-first"} =
             Loopex.command(
               attachment,
               prompt("recovered-first", %{bounds: %{deadline_at_ms: active_ceiling}})
             )

    follow = %{
      type: :follow_up,
      command_id: "recovered-next",
      content: "next",
      bounds: %{deadline_at_ms: queued_ceiling}
    }

    assert {:accepted, "recovered-next"} = Loopex.command(attachment, follow)

    assert {:ok, {:prepared, activation}} =
             Loopex.prepare_resume_session(fixture.runtime, session, "prepared-queued")

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    recovered = owner(fixture)
    state = :sys.get_state(recovered)
    active = state.durable.active_run_id
    queued = SessionState.command_run_id(session, "recovered-next")
    assert Enum.sort(Map.keys(state.deadline_allowances)) == Enum.sort([active, queued])
    assert state.deadline_allowances[queued] > state.deadline_allowances[active]
    spent = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(
      recovered,
      &%{&1 | deadline_allowances: %{active => spent, queued => spent}}
    )

    assert System.system_time(:millisecond) < active_ceiling
    assert {:ok, ^session} = Loopex.activate_resume(activation)
    first = terminal(attachment)
    second = terminal(attachment)
    assert first["run_id"] == active
    assert first["observed"] == active_ceiling
    assert second["run_id"] == queued
    assert second["observed"] == queued_ceiling
    assert first["outcome"] == "bound_reached"
    assert second["outcome"] == "bound_reached"
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert AgentLoopTestExecutor.jobs(fixture.executor) == []

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "model_request_committed_v2")
           )

    assert {:accepted, "recovered-next"} = Loopex.command(attachment, follow)
  end

  test "actual executor entry after its paired cutoff invokes no port and retains cancelled predispatch truth" do
    {fixture, session, attachment} =
      fixture(
        script: [
          %{
            hold: self(),
            text: "work",
            calls: [%{id: "bounded-executor", name: "write", arguments: %{"path" => "x"}}]
          },
          %{text: "must not continue"}
        ]
      )

    assert {:accepted, "executor-cutoff"} = Loopex.command(attachment, prompt("executor-cutoff"))
    assert_receive {:holding, model_worker}, 5_000
    coordinator = owner(fixture)
    cutoff = install_callback_cutoff(coordinator, self())
    send(model_worker, :release)
    assert_receive {:native_callback_waiting, :executor, worker, reference}, 5_000
    monitor = Process.monitor(worker)
    deadline = owner_deadline(coordinator)
    true = :erlang.suspend_process(coordinator)
    wait_past_monotonic(cutoff)
    assert System.system_time(:millisecond) < deadline
    send(worker, {:native_callback_release, reference})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert AgentLoopTestExecutor.jobs(fixture.executor) == []
    true = :erlang.resume_process(coordinator)
    finished = terminal(attachment)
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    events = Fixture.events(fixture, session)
    [tool] = Enum.filter(events, &(&1.kind == "tool.finished"))
    assert tool["outcome"] == "cancelled"
    assert tool["reason"] == "the run deadline passed before dispatch"

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "executor_receipt_committed_v2")
           )
  end

  test "artifact preparation worker delayed past its paired cutoff never enters retention" do
    {fixture, session, attachment, artifact} = artifact_callback_fixture(:entry)
    coordinator = owner(fixture)
    assert_receive {:tool_progress_emitted, _call, executor}, 5_000
    cutoff = install_callback_cutoff(coordinator, self())
    deadline = owner_deadline(coordinator)
    send(executor, :release)
    assert_receive {:native_callback_waiting, :artifact_preparation, worker, reference}, 5_000
    monitor = Process.monitor(worker)
    true = :erlang.suspend_process(coordinator)
    wait_past_monotonic(cutoff)
    assert System.system_time(:millisecond) < deadline
    send(worker, {:native_callback_release, reference})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    refute_received {:artifact_put, _, _, _}
    assert Agent.get(artifact, & &1.objects) == %{}
    true = :erlang.resume_process(coordinator)
    assert terminal(attachment)["bound"] == "deadline"

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "tool_result_reference_prepared")
           )

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "successful actual artifact retention processed after its paired cutoff cannot commit preparation success" do
    {fixture, session, attachment, artifact} = artifact_callback_fixture(:result)
    coordinator = owner(fixture)
    assert_receive {:tool_progress_emitted, _call, executor}, 5_000
    cutoff = install_callback_cutoff(coordinator, nil)
    deadline = owner_deadline(coordinator)
    send(executor, :release)
    assert_receive {:artifact_put, worker, _bytes, _metadata}, 5_000
    monitor = Process.monitor(worker)
    true = :erlang.suspend_process(coordinator)
    # Concept: result adoption must enforce its own fence independently of timers.
    # Technical depth: let the real worker produce success before the original
    # cutoff. Its result and DOWN then precede every cutoff timer in the frozen
    # owner's mailbox; resume only after that allowance is spent. A timer-only
    # fix would wrongly commit this already-queued successful reference first.
    send(worker, :retain_source)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert System.monotonic_time(:millisecond) < cutoff
    assert map_size(Agent.get(artifact, & &1.objects)) == 1
    wait_past_monotonic(cutoff)
    assert System.system_time(:millisecond) < deadline
    true = :erlang.resume_process(coordinator)
    assert terminal(attachment)["bound"] == "deadline"
    records = Fixture.records(fixture, session)
    assert Enum.count(records, &(&1.payload.kind == "executor_receipt_committed_v2")) == 1
    assert Enum.count(records, &(&1.payload.kind == "tool_result_preparation_state_v1")) == 1
    refute Enum.any?(records, &(&1.payload.kind == "tool_result_reference_prepared"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "artifact success queued before a tightened run timer cannot adopt under its older worker allowance" do
    {fixture, session, attachment, artifact} = artifact_callback_fixture(:result)
    coordinator = owner(fixture)
    assert_receive {:tool_progress_emitted, _call, executor}, 5_000
    send(executor, :release)
    assert_receive {:artifact_put, worker, _bytes, _metadata}, 5_000
    monitor = Process.monitor(worker)
    state = :sys.get_state(coordinator)
    run = state.durable.active_run_id

    [{reference, {:artifact_preparation, ^run, ^worker, metadata}}] =
      Enum.filter(state.in_flight, fn
        {_reference, {:artifact_preparation, ^run, ^worker, _metadata}} -> true
        _ -> false
      end)

    original_cutoff = metadata.monotonic_deadline
    deadline = owner_deadline(coordinator)
    tighter_cutoff = System.monotonic_time(:millisecond) + 1_000
    assert tighter_cutoff < original_cutoff

    # Concept: a live command can shorten the allowance after retention starts.
    # Technical depth: install that reduction through the private state seam,
    # preserving the actual worker's original metadata and the retained UTC
    # deadline. Arm the ordinary run timer against the tighter original cutoff;
    # this models a forward wall sample followed by rollback without changing UTC.
    :sys.replace_state(coordinator, fn state ->
      assert state.in_flight[reference] == {:artifact_preparation, run, worker, metadata}
      if previous = state.deadline_timers[run], do: Process.cancel_timer(previous)

      timer =
        Process.send_after(
          coordinator,
          {:run_deadline, run, deadline},
          max(tighter_cutoff - System.monotonic_time(:millisecond), 0)
        )

      %{
        state
        | deadline_allowances: Map.put(state.deadline_allowances, run, tighter_cutoff),
          deadline_timers: Map.put(state.deadline_timers, run, timer)
      }
    end)

    true = :erlang.suspend_process(coordinator)
    send(worker, :retain_source)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert System.monotonic_time(:millisecond) < tighter_cutoff
    assert map_size(Agent.get(artifact, & &1.objects)) == 1
    wait_past_monotonic(tighter_cutoff)
    assert System.monotonic_time(:millisecond) < original_cutoff
    assert System.system_time(:millisecond) < deadline
    true = :erlang.resume_process(coordinator)
    finished = terminal(attachment)
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    assert finished["observed"] == deadline
    records = Fixture.records(fixture, session)
    assert Enum.count(records, &(&1.payload.kind == "executor_receipt_committed_v2")) == 1
    assert Enum.count(records, &(&1.payload.kind == "tool_result_preparation_state_v1")) == 1
    refute Enum.any?(records, &(&1.payload.kind == "tool_result_reference_prepared"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "actual follow-up rearming preserves the allowance already captured by an executor worker" do
    {fixture, session, attachment} =
      fixture(
        script: [
          %{
            hold: self(),
            text: "work",
            calls: [
              %{id: "stable-allowance", name: "write", arguments: %{"path" => "x"}}
            ]
          },
          %{text: "first done"},
          %{text: "follow-up done"}
        ]
      )

    assert {:accepted, "stable-first"} = Loopex.command(attachment, prompt("stable-first"))
    assert_receive {:holding, model_worker}, 5_000
    coordinator = owner(fixture)
    deadline = owner_deadline(coordinator)

    captured_cutoff =
      System.monotonic_time(:millisecond) +
        max(deadline - System.system_time(:millisecond), 0) + 10_000

    # Concept: a rollback leaves the original allowance longer than a fresh sample.
    # Technical depth: install that private capture relation before the actual
    # executor takes its immutable copy, with UTC and the retained deadline
    # unchanged. An incidental recapture would deterministically shorten it.
    # The existing wall fence still bounds this greater monotonic allowance.
    observer = self()

    :sys.replace_state(coordinator, fn state ->
      state
      |> Map.put(:native_callback_gate, observer)
      |> Map.put(:deadline_allowances, %{state.durable.active_run_id => captured_cutoff})
    end)

    send(model_worker, :release)
    assert_receive {:native_callback_waiting, :executor, worker, reference}, 5_000
    monitor = Process.monitor(worker)
    before = :sys.get_state(coordinator)
    run = before.durable.active_run_id
    assert before.deadline_allowances[run] == captured_cutoff
    follow = %{type: :follow_up, command_id: "stable-next", content: "next"}
    assert {:accepted, "stable-next"} = Loopex.command(attachment, follow)
    after_command = :sys.get_state(coordinator)
    assert after_command.deadline_allowances[run] == captured_cutoff
    assert after_command.durable.follow_up.command_id == "stable-next"
    assert after_command.durable.deadlines[run] == deadline
    assert is_reference(after_command.deadline_timers[run])
    assert System.system_time(:millisecond) < deadline
    # Only this executor's already-captured gate is held; later ordinary staging
    # uses its normal absent observer and completes both accepted runs.
    :sys.replace_state(coordinator, &Map.put(&1, :native_callback_gate, nil))
    send(worker, {:native_callback_release, reference})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert terminal(attachment)["outcome"] == "completed"
    assert terminal(attachment)["outcome"] == "completed"
    assert length(AgentLoopTestExecutor.jobs(fixture.executor)) == 1
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 3

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "executor_receipt_committed_v2")
           ) == 1
  end

  test "run-owned maintenance success queued before cutoff cannot stage after its current paired allowance" do
    {fixture, session, run, activation, ceiling} = retained_maintenance_owner()
    coordinator = owner(fixture)
    observer = self()
    :sys.replace_state(coordinator, &Map.put(&1, :native_callback_gate, observer))
    assert {:ok, ^session} = Loopex.activate_resume(activation)

    assert_receive {:native_callback_waiting, :maintenance_preparation, worker, gate_reference},
                   5_000

    state = :sys.get_state(coordinator)

    [{task_reference, {:maintenance_preparation, ^run, ^worker, metadata}}] =
      Enum.filter(state.in_flight, fn
        {_ref, {:maintenance_preparation, ^run, ^worker, _}} -> true
        _ -> false
      end)

    assert metadata.origin == :run
    assert metadata.deadline == ceiling
    cutoff = System.monotonic_time(:millisecond) + 1_000
    assert cutoff < state.deadline_allowances[run]

    :sys.replace_state(coordinator, fn state ->
      if previous = state.deadline_timers[run], do: Process.cancel_timer(previous)

      timer =
        Process.send_after(
          coordinator,
          {:run_deadline, run, ceiling},
          max(cutoff - System.monotonic_time(:millisecond), 0)
        )

      %{
        state
        | deadline_allowances: Map.put(state.deadline_allowances, run, cutoff),
          deadline_timers: Map.put(state.deadline_timers, run, timer)
      }
    end)

    {:ok, attachment} =
      Loopex.attach(fixture.runtime, session, after_event_sequence: state.durable.event_sequence)

    monitor = Process.monitor(worker)
    :erlang.trace(worker, true, [:send])
    true = :erlang.suspend_process(coordinator)
    send(worker, {:native_callback_release, gate_reference})
    assert_receive {:trace, ^worker, :send, {^task_reference, {:ok, proposal}}, _recipient}, 5_000
    kinds = Enum.map(proposal.records, & &1.kind)
    assert "maintenance_request_committed_v1" in kinds
    assert "maintenance_attempt_opened_v1" in kinds
    request = Enum.find(proposal.records, &(&1.kind == "maintenance_request_committed_v1"))
    assert request["eligible_unit_count"] == 1
    assert request["covered_range"]["unit_count"] == 1
    assert request["source_excerpted"] == true
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert System.monotonic_time(:millisecond) < cutoff
    wait_past_monotonic(cutoff)
    assert System.system_time(:millisecond) < ceiling
    true = :erlang.resume_process(coordinator)
    finished = terminal(attachment)
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    assert finished["observed"] == ceiling
    records = Fixture.records(fixture, session)

    refute Enum.any?(
             records,
             &(&1.payload.kind in [
                 "maintenance_request_committed_v1",
                 "maintenance_attempt_opened_v1"
               ])
           )

    assert Enum.count(records, &(&1.payload.kind == "maintenance_episode_terminal_v1")) == 1
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "ordinary successful construction cannot stage after its retained absolute allowance" do
    assert_staging_adoption_cutoff(:fits)
  end

  test "ordinary refused construction cannot start maintenance after its retained absolute allowance" do
    assert_staging_adoption_cutoff(:refused)
  end

  defp assert_staging_adoption_cutoff(disposition) do
    options =
      if disposition == :refused,
        do: [context_token_budget: 800, system_class_tokens: 800, tools: []],
        else: []

    {fixture, session, attachment} =
      fixture(Keyword.put(options, :script, [%{text: "must not enter"}]))

    coordinator = owner(fixture)
    model = :sys.get_state(coordinator).model
    :sys.replace_state(coordinator, &%{&1 | model: nil})
    ceiling = System.system_time(:millisecond) + 60_000
    content = if disposition == :refused, do: String.duplicate("x", 20_000), else: "implement"

    command = %{
      type: :prompt,
      command_id: "staging-cutoff",
      content: content,
      bounds: %{deadline_at_ms: ceiling}
    }

    assert {:accepted, "staging-cutoff"} = Loopex.command(attachment, command)
    observer = self()
    cutoff = System.monotonic_time(:millisecond) + 1_000

    :sys.replace_state(coordinator, fn state ->
      state
      |> Map.put(:model, model)
      |> Map.put(:native_callback_gate, observer)
      |> Map.put(:deadline_allowances, %{state.durable.active_run_id => cutoff})
    end)

    send(coordinator, :advance_work)
    assert_receive {:native_callback_waiting, :ordinary_staging, ^coordinator, reference}, 5_000
    wait_past_monotonic(cutoff)
    assert System.system_time(:millisecond) < ceiling
    send(coordinator, {:native_callback_release, reference})
    finished = terminal(attachment)
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    assert finished["observed"] == ceiling

    forbidden = [
      "model_request_committed_v2",
      "model_attempt_opened_v1",
      "maintenance_episode_admitted_v1",
      "context_admission_refused_v2"
    ]

    refute Enum.any?(Fixture.records(fixture, session), &(&1.payload.kind in forbidden))
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert {:accepted, "staging-cutoff"} = Loopex.command(attachment, command)
  end

  # Concept: a real recovered maintenance source supplies a queued worker proposal.
  # Technical depth: reuse the existing retained-episode fixture pattern: exact
  # creation, stop its idle owner, and commit pure current reducer proposals
  # through Store. The prepared successor then owns the real source worker.
  defp retained_maintenance_owner do
    seed = Fixture.start(script: [], tools: [])
    on_exit(fn -> Fixture.stop(seed) end)
    configuration = ConfiguredGenesisFixture.configuration()

    {:ok, session} =
      Loopex.create_session(seed.runtime, %{},
        command_id: "maintenance-create",
        genesis: ConfiguredGenesisFixture.genesis([], configuration)
      )

    assert :ok = Loopex.stop(seed.runtime)

    {:ok, current} =
      SessionState.recover(session, Fixture.records(seed, session), Fixture.events(seed, session))

    # Concept: the worker must construct a successful contracting request.
    # Technical depth: this settled 30,000-byte older unit exceeds the ordinary
    # 8,192-token window after its 1,024-token reply reserve, while the small
    # protected prompt fits alone. Automatic selection must remove one old unit;
    # the 16,384-byte source envelope excerpts it without changing any bound.
    {:ok, old} =
      SessionState.propose(
        current,
        %{type: :prompt, command_id: "maintenance-old", content: String.duplicate("old ", 7_500)},
        resolved()
      )

    current = retain_bounds_proposal(seed, current, old)

    {:ok, finished} =
      SessionState.propose_run_terminal(current, current.active_run_id, "failed", %{
        reason: "model_call_failed"
      })

    current = retain_bounds_proposal(seed, current, finished)
    ceiling = System.system_time(:millisecond) + 60_000

    {:ok, active} =
      SessionState.propose(
        current,
        prompt("maintenance-active", %{bounds: %{deadline_at_ms: ceiling}}),
        resolved(%{admitted_at: System.system_time(:millisecond)})
      )

    current = retain_bounds_proposal(seed, current, active)

    selection = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none"]
      },
      "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      Loopex.Runtime.MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Keep the facts"
      })

    {:ok, episode} =
      SessionState.propose_maintenance_episode(
        current,
        current.active_run_id,
        selection,
        instructions,
        System.system_time(:millisecond)
      )

    current = retain_bounds_proposal(seed, current, episode)
    fixture = Fixture.start(store: seed.store, tools: [], script: [%{text: "must not enter"}])
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "maintenance-prepare")

    {fixture, session, current.active_run_id, activation, ceiling}
  end

  defp retain_bounds_proposal(fixture, state, proposal) do
    {:ok, store} = Loopex.Store.new(Loopex.M1RuntimeTestStore, fixture.store)

    {:ok, transaction} =
      Loopex.Store.session_commit(
        state.session_id,
        "session",
        proposal.tx_id,
        state.owner_epoch,
        state.owner_incarnation_id,
        state.journal_version,
        proposal.records,
        proposal.events
      )

    assert {:committed, _tx, receipt} = Loopex.Store.transact(store, transaction)
    assert {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    next
  end

  defp owner(fixture) do
    {:ok, %{sessions: sessions}} = Loopex.Runtime.children(fixture.runtime)
    [{_, owner, _, _}] = DynamicSupervisor.which_children(sessions)
    owner
  end

  # Concept: a spent monotonic allowance with an open wall ceiling models rollback.
  # Technical depth: the private state seam changes neither UTC nor any retained
  # request. Install the earlier allowance before the real worker captures it;
  # all later entry/result fences must retain that exact original cutoff.
  defp install_callback_cutoff(coordinator, gate) do
    cutoff = System.monotonic_time(:millisecond) + 1_000

    :sys.replace_state(coordinator, fn state ->
      state
      |> Map.put(:native_callback_gate, gate)
      |> Map.put(:deadline_allowances, %{state.durable.active_run_id => cutoff})
    end)

    cutoff
  end

  defp owner_deadline(coordinator) do
    state = :sys.get_state(coordinator)
    {declared, _} = SessionState.accounting(state.durable, state.durable.active_run_id)
    declared.deadline || declared.deadline_at_ms
  end

  defp wait_past_monotonic(cutoff) do
    if System.monotonic_time(:millisecond) < cutoff do
      Process.sleep(5)
      wait_past_monotonic(cutoff)
    end
  end

  defp artifact_callback_fixture(cut) do
    {:ok, artifact} =
      BoundsArtifactStore.start(observer: self(), gate: if(cut == :result, do: :hold))

    on_exit(fn -> if Process.alive?(artifact), do: Agent.stop(artifact) end)

    [range] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    {fixture, session, attachment} =
      fixture(
        artifact_store: %{module: BoundsArtifactStore, handle: artifact},
        tools: [Fixture.tool_definition(), range["definition"]],
        tool_progress_gate: self(),
        script: [
          %{
            text: "work",
            calls: [
              %{
                id: String.duplicate("\"", 1_000),
                name: "write",
                arguments: %{"path" => "output"}
              }
            ]
          },
          %{text: "must not continue"}
        ]
      )

    assert {:accepted, "artifact-cutoff"} = Loopex.command(attachment, prompt("artifact-cutoff"))
    {fixture, session, attachment, artifact}
  end
end

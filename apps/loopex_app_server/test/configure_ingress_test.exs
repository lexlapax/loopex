Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/model_preparation_conformance.exs", __DIR__)

defmodule Loopex.AppServer.ConfigureIngressTest do
  use ExUnit.Case, async: true

  alias Loopex.AppServer.Mapping, as: Adapter
  alias Loopex.AppServer.Connection
  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.{Frame, Session.ConfigureRequest}

  defmodule Preparing do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, progress) do
      Loopex.AgentLoopTestModel.complete(
        request,
        Keyword.take(options, [:script, :max_tokens]),
        progress
      )
    end

    @impl true
    def prepare_configuration(current, authored, definitions, _context, options) do
      worker = self()

      canonical =
        Agent.get_and_update(Keyword.fetch!(options, :controller), fn state ->
          {state.canonical,
           Map.put(%{state | calls: state.calls + 1}, :preparation_worker, worker)}
        end)

      Loopex.ModelPreparationConformance.candidate(current, authored, definitions, canonical)
    end
  end

  test "all admitted literal foreground requests preserve exact native authored values and capture instructions" do
    for vector <- vectors()["cases"],
        vector["transport"] == "foreground",
        vector["error"] != true do
      request = vector["input"]
      assert {:ok, decoded} = ConfigureRequest.decode_wire(request, :foreground)
      assert {:ok, prepared} = Adapter.prepare_configuration_request(request)

      expected =
        if Map.has_key?(decoded.changes, "instructions") do
          assert {:ok, captured} =
                   Loopex.Runtime.Instructions.capture(decoded.changes["instructions"])

          Map.put(decoded.changes, "instructions", captured)
        else
          decoded.changes
        end

      assert prepared == %{decoded | changes: expected}, vector["name"]
      assert Loopex.Runtime.SessionConfiguration.validate_update(prepared.changes) == :ok
    end
  end

  test "instruction capture retains authored aliases bytes and deterministic rendered digest" do
    request = request()
    assert {:ok, prepared} = Adapter.prepare_configuration_request(request)
    raw = request["changes"]["instructions"]
    captured = prepared.changes["instructions"]
    assert Map.delete(captured, "digest") == raw

    assert captured["digest"] ==
             "40e32aaecf50de1888225a4e98670fdb54619568cd07308b0f1395903da183e4"

    rendered =
      raw["version"] <>
        ": " <>
        Enum.join(
          Enum.reject([raw["base"], raw["environment"], raw["appendix"]], &(&1 == "")),
          "\n\n"
        )

    assert captured["digest"] == :crypto.hash(:sha256, rendered) |> Base.encode16(case: :lower)
    assert prepared.changes["model"] == " alias/model "
    assert prepared.changes["max_tokens"] == 9_007_199_254_740_993
    assert prepared.changes["context_token_budget"] == 18_446_744_073_709_551_615
    assert prepared.command_id == <<0, 255, 1, 128>>
    refute Map.has_key?(prepared, :writer_epoch)
  end

  test "all refused transport vectors and private instruction facts refuse before native preparation" do
    for vector <- vectors()["cases"], vector["transport"] == "foreground", vector["error"] do
      assert Adapter.prepare_configuration_request(vector["input"]) == {:error, :invalid_request},
             vector["name"]
    end

    request = request()

    for key <- ~w(digest file metadata authority) do
      invalid = update_in(request, ["changes", "instructions"], &Map.put(&1, key, "private"))
      assert Adapter.prepare_configuration_request(invalid) == {:error, :invalid_request}
    end
  end

  test "native whole-update limit remains effective after valid field decoding" do
    request =
      Map.put(request(), "changes", %{
        "model" => String.duplicate("m", Loopex.Store.max_item_bytes())
      })

    assert {:ok, decoded} = ConfigureRequest.decode_wire(request, :foreground)
    assert decoded.changes["model"] == request["changes"]["model"]
    assert {:error, {:item_too_large, _, _}} = Loopex.Store.admit_bounded(decoded.changes)
    assert Adapter.prepare_configuration_request(request) == {:error, :invalid_request}
  end

  test "duplicate-aware Frame and current configure inventory retain their exact contract" do
    for vector <- vectors()["frame_cases"] do
      assert Frame.decode(vector["json"], 2_097_152) == {:error, :duplicate_member}
    end

    assert Adapter.implemented?("session.configure")
    assert "session.configure" in LoopexProtocol.Session.methods()

    assert {:error, %{"code" => "not_attached"}} =
             Adapter.call(%{"method" => "session.configure"}, %{})
  end

  test "configure mapping retains native parity while rendering only correlated admission" do
    mapped = native_fixture()
    native = native_fixture()
    request = native_request()
    context = %{runtime: mapped.runtime, attachment: mapped.attachment}
    assert {:ok, prepared} = Adapter.prepare_configuration_request(request)
    assert {:ok, reply} = Adapter.call(request, context)

    assert reply == %{
             "type" => "admission",
             "method" => "session.configure",
             "request_id" => "configure",
             "command_id" => request["command_id"],
             "status" => "accepted",
             "reason" => nil
           }

    refute Process.alive?(Agent.get(mapped.controller, & &1.preparation_worker))

    assert {:accepted, accepted_id} =
             Loopex.command(native.attachment, %{
               type: :configure,
               command_id: prepared.command_id,
               changes: prepared.changes
             })

    assert accepted_id == <<0, 255, 1, 128>>
    assert [mapped_record] = configuration_records(mapped)
    assert [native_record] = configuration_records(native)
    assert mapped_record.payload == native_record.payload
    assert [mapped_event] = Fixture.events(mapped, mapped.session)
    assert [native_event] = Fixture.events(native, native.session)
    assert Map.drop(mapped_event, [:event_id]) == Map.drop(native_event, [:event_id])
    assert {:ok, status} = Loopex.session_status(mapped.runtime, mapped.session)
    assert status.configuration == mapped_event["configuration"]
    public = :erlang.term_to_binary({reply, status.configuration, mapped_event})

    for private <- [
          "INGRESS_PRIVATE_INSTRUCTIONS",
          "INGRESS_HOST_OPTION",
          "provider_mapping",
          "model_capabilities"
        ] do
      refute public =~ private
    end

    assert Loopex.AgentLoopTestModel.dispatched(mapped.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(mapped.executor) == []

    before_records = Fixture.records(mapped, mapped.session)
    before_events = Fixture.events(mapped, mapped.session)
    Agent.update(mapped.controller, &%{&1 | canonical: "scripted:v2"})
    retry = %{request | "request_id" => "retry"}
    assert {:ok, retried} = Adapter.call(retry, context)
    assert retried == %{reply | "request_id" => "retry"}
    conflict = put_in(request, ["changes", "model"], "scripted:v1")
    assert {:ok, refused} = Adapter.call(conflict, context)
    assert refused == %{reply | "status" => "refused", "reason" => "idempotency_conflict"}
    assert Fixture.records(mapped, mapped.session) == before_records
    assert Fixture.events(mapped, mapped.session) == before_events
    assert Agent.get(mapped.controller, & &1.calls) == 1
  end

  test "configure mapping preserves attachment and closed-input refusals before native work" do
    fixture = native_fixture()
    request = native_request()
    context = %{runtime: fixture.runtime, attachment: fixture.attachment}
    before_records = Fixture.records(fixture, fixture.session)

    assert {:error, %{"code" => "not_attached"}} =
             Adapter.call(request, %{runtime: fixture.runtime})

    stale = %{context | attachment: %{fixture.attachment | incarnation_id: "stale-incarnation"}}
    assert {:ok, stale_reply} = Adapter.call(request, stale)
    assert stale_reply["status"] == "refused"
    assert stale_reply["reason"] == "session_unavailable"
    assert stale_reply["command_id"] == request["command_id"]

    for invalid <- [
          Map.put(request, "session_id", "unadmitted-session"),
          put_in(request, ["changes", "instructions", "digest"], String.duplicate("a", 64)),
          put_in(request, ["changes", "model_capabilities"], %{}),
          put_in(request, ["changes", "max_tokens"], 512)
        ] do
      assert {:error, refusal} = Adapter.call(invalid, context)
      assert refusal["type"] == "error"
      assert refusal["code"] == "invalid_request"
      assert refusal["request_id"] == request["request_id"]
      refute Map.has_key?(refusal, "status")
    end

    for request_id <- [
          "bad id",
          "bad/id",
          "12345678901234567890123456789012345678901234567890123456789012345",
          17,
          %{"private" => "INGRESS_REJECTED_ID_CANARY"},
          nil,
          <<255>>
        ] do
      assert {:error, refusal} = Adapter.call(%{request | "request_id" => request_id}, context)

      assert refusal == %{
               "type" => "error",
               "code" => "invalid_request",
               "message" => "a field is missing or not in its wire representation",
               "request_id" => nil
             }

      refute :erlang.term_to_binary(refusal) =~ "INGRESS_REJECTED_ID_CANARY"
    end

    assert Fixture.records(fixture, fixture.session) == before_records
    assert Fixture.events(fixture, fixture.session) == []
    assert Agent.get(fixture.controller, & &1.calls) == 0
  end

  test "current connection refuses pre-initialization and extra configure fields before any callback or durable work" do
    fixture = native_fixture()
    request = native_request()
    before_records = Fixture.records(fixture, fixture.session)
    fresh = Connection.new(runtime: fixture.runtime)
    assert {:error, early, ^fresh} = Connection.dispatch(fresh, request)
    assert early["code"] == "not_initialized"

    assert {:ok, initialized, connection} =
             Connection.initialize(fresh, %{
               "method" => "initialize",
               "request_id" => "initialize",
               "generations" => [LoopexProtocol.Session.generation()],
               "capabilities" => []
             })

    assert initialized["selected_generation"] == "loopex.experimental/3"
    assert initialized["exact_schema_sha256"] == LoopexProtocol.Session.schema_digest()
    assert initialized["supported_methods"] == LoopexProtocol.Session.methods()
    assert "session.configure" in initialized["supported_methods"]
    attached = Connection.attach(connection, fixture.attachment)
    assert {:error, refusal, ^attached} = Connection.dispatch(attached, Map.put(request, "writer_epoch", "forbidden-foreground-authority"))
    assert refusal["code"] == "invalid_request"
    assert refusal["request_id"] == request["request_id"]
    refute Map.has_key?(refusal, "status")
    assert Fixture.records(fixture, fixture.session) == before_records
    assert Fixture.events(fixture, fixture.session) == []
    assert Agent.get(fixture.controller, & &1.calls) == 0
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "configure mapping renders settledness refusal while the actual model run is active" do
    fixture = native_fixture([%{hold: self(), text: "done", calls: []}])
    request = native_request()
    context = %{runtime: fixture.runtime, attachment: fixture.attachment}

    assert {:accepted, "held-prompt"} =
             Loopex.command(fixture.attachment, %{
               type: :prompt,
               command_id: "held-prompt",
               content: "hold"
             })

    assert_receive {:holding, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:ok, reply} = Adapter.call(request, context)

    assert reply == %{
             "type" => "admission",
             "method" => "session.configure",
             "request_id" => request["request_id"],
             "command_id" => request["command_id"],
             "status" => "refused",
             "reason" => "configuration_not_settled"
           }

    assert [refusal] = configuration_records(fixture)
    assert refusal.payload["admission"] == "rejected_configuration_not_settled"
    assert refusal.payload["configuration"] == nil
    assert Agent.get(fixture.controller, & &1.calls) == 0
    refute Enum.any?(Fixture.events(fixture, fixture.session), &(&1.kind == "session.configured"))
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
    cutoff = System.monotonic_time(:millisecond) + 5_000

    terminal =
      Enum.find(completed_events(fixture.attachment, cutoff), &(&1.kind == "run.finished"))

    assert terminal["outcome"] == "completed"
    assert {:ok, status} = Loopex.session_status(fixture.runtime, fixture.session)
    assert status.configuration["configuration_version"] == 1
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @configuration_phase phase
    test "configure mapping retains the original proposal through #{@configuration_phase} uncertainty" do
      fixture = native_fixture()
      request = native_request()
      context = %{runtime: fixture.runtime, attachment: fixture.attachment}
      kind = "session_configuration_admitted_v2"

      assert :ok =
               Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 kind,
                 self()
               )

      observer = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          send(observer, {:mapped_configure, self(), Adapter.call(request, context)})
        end)

      on_exit(fn ->
        cleanup_monitor = Process.monitor(caller)
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        assert_receive {:DOWN, ^cleanup_monitor, :process, ^caller, _reason}, 1_000
      end)

      assert_receive {:record_held_before_linearization, waiter, store, ^kind, transaction}, 5_000
      waiter_monitor = Process.monitor(waiter)

      on_exit(fn ->
        cleanup_monitor = Process.monitor(waiter)
        if Process.alive?(waiter), do: Process.exit(waiter, :kill)
        assert_receive {:DOWN, ^cleanup_monitor, :process, ^waiter, _reason}, 1_000
      end)

      assert store == fixture.store
      assert Agent.get(fixture.controller, & &1.calls) == 1
      refute Process.alive?(Agent.get(fixture.controller, & &1.preparation_worker))
      Agent.update(fixture.controller, &%{&1 | canonical: "scripted:v2"})

      assert :ok =
               Loopex.M1RuntimeTestStore.inject(
                 store,
                 {:session_journal_commit, @configuration_phase}
               )

      Loopex.M1RuntimeTestStore.release(waiter)
      assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :normal}, 1_000
      assert_receive {:mapped_configure, ^caller, result}, 5_000
      assert {:error, unknown} = result
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000

      assert unknown == %{
               "type" => "error",
               "code" => "admission_unknown",
               "request_id" => request["request_id"],
               "message" => "the outcome of this command is not yet known"
             }

      refute Map.has_key?(unknown, "status")
      cutoff = System.monotonic_time(:millisecond) + 5_000
      await_configuration_disposition(fixture.attachment, <<0, 255, 1, 128>>, cutoff)
      assert {:ok, retry} = Adapter.call(%{request | "request_id" => "retry"}, context)
      assert retry["status"] == "accepted"
      assert retry["command_id"] == request["command_id"]
      assert retry["request_id"] == "retry"
      assert [retained] = configuration_records(fixture)
      assert retained.payload == hd(transaction.records)
      assert retained.payload["configuration"]["model"] == "scripted:v1"
      assert [event] = Fixture.events(fixture, fixture.session)
      assert event.kind == "session.configured"
      assert event["configuration"]["model"] == "scripted:v1"
      assert Agent.get(fixture.controller, & &1.calls) == 1

      assert {:session_journal_commit, @configuration_phase} in Loopex.M1RuntimeTestStore.observed(
               store
             )

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
      assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
      public = :erlang.term_to_binary({unknown, retry, event})

      for private <- [
            "INGRESS_PRIVATE_INSTRUCTIONS",
            "INGRESS_HOST_OPTION",
            "provider_mapping",
            "model_capabilities"
          ] do
        refute public =~ private
      end
    end
  end

  defp await_configuration_disposition(attachment, command_id, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff
    actual = Loopex.command_disposition(attachment, command_id)
    assert System.monotonic_time(:millisecond) <= cutoff, inspect(actual)

    unless actual == {:ok, {:committed, :admitted, :accepted, nil}} do
      Process.sleep(min(10, max(cutoff - System.monotonic_time(:millisecond), 0)))
      await_configuration_disposition(attachment, command_id, cutoff)
    end
  end

  # Concept: captured wire changes admit the same durable command as native input.
  # Technical depth: these cases cross the real serial owner and optional Model
  # preparation boundary. They do not negotiate or serve the dormant wire method.
  test "captured foreground changes match native durability and public output without repeating preparation" do
    captured = native_fixture()
    native = native_fixture()
    request = native_request()
    assert {:ok, prepared} = Adapter.prepare_configuration_request(request)
    command = %{type: :configure, command_id: prepared.command_id, changes: prepared.changes}

    assert {:ok, instructions} =
             Loopex.Runtime.Instructions.capture(request["changes"]["instructions"])

    authored = %{
      "model" => " alias/model ",
      "reasoning" => "default",
      "instructions" => instructions,
      "max_tokens" => 512,
      "context_token_budget" => 6_000,
      "system_class_tokens" => 5_000
    }

    direct = %{type: :configure, command_id: <<0, 255, 1, 128>>, changes: authored}
    assert command == direct
    assert {:accepted, accepted_id} = Loopex.command(captured.attachment, command)
    assert accepted_id == <<0, 255, 1, 128>>
    assert {:accepted, ^accepted_id} = Loopex.command(native.attachment, direct)

    assert [retained] = configuration_records(captured)
    assert [native_retained] = configuration_records(native)
    assert retained.payload == native_retained.payload
    assert retained.payload["command_id"] == accepted_id

    assert retained.payload["changes"] ==
             %{authored | "instructions" => Map.take(instructions, ~w(version digest))}

    assert retained.payload["configuration"]["model"] == "scripted:v1"
    assert retained.payload["configuration"]["instructions"] == instructions

    assert [event] = Fixture.events(captured, captured.session)
    assert [native_event] = Fixture.events(native, native.session)
    assert Map.drop(event, [:event_id]) == Map.drop(native_event, [:event_id])
    assert event.kind == "session.configured"
    assert event["command_id"] == accepted_id

    assert event["configuration"]["instructions"] ==
             Map.take(instructions, ~w(version digest))

    assert {:ok, status} = Loopex.session_status(captured.runtime, captured.session)
    assert {:ok, native_status} = Loopex.session_status(native.runtime, native.session)
    assert status.configuration == native_status.configuration
    assert status.configuration == event["configuration"]

    public =
      :erlang.term_to_binary({status.configuration, Fixture.events(captured, captured.session)})

    for private <- [
          "INGRESS_PRIVATE_INSTRUCTIONS",
          "INGRESS_HOST_OPTION",
          "provider_mapping",
          "model_capabilities"
        ] do
      refute public =~ private
    end

    assert Loopex.AgentLoopTestModel.dispatched(captured.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(captured.executor) == []
    assert Agent.get(captured.controller, & &1.calls) == 1

    before_records = Fixture.records(captured, captured.session)
    before_events = Fixture.events(captured, captured.session)
    Agent.update(captured.controller, &%{&1 | canonical: "scripted:v2"})

    assert {:ok, retry} =
             Adapter.prepare_configuration_request(%{request | "request_id" => "retry"})

    assert {:accepted, ^accepted_id} =
             Loopex.command(captured.attachment, %{
               type: :configure,
               command_id: retry.command_id,
               changes: retry.changes
             })

    assert Fixture.records(captured, captured.session) == before_records
    assert Fixture.events(captured, captured.session) == before_events
    assert Agent.get(captured.controller, & &1.calls) == 1

    conflict = put_in(request, ["changes", "model"], "scripted:v1")
    assert {:ok, conflict} = Adapter.prepare_configuration_request(conflict)

    assert {:error, :idempotency_conflict} =
             Loopex.command(captured.attachment, %{
               type: :configure,
               command_id: conflict.command_id,
               changes: conflict.changes
             })

    assert Fixture.records(captured, captured.session) == before_records
    assert Fixture.events(captured, captured.session) == before_events
    assert Agent.get(captured.controller, & &1.calls) == 1
  end

  test "captured foreground changes cannot bypass attachment authority or active-run exclusion" do
    fixture = native_fixture([%{hold: self(), text: "done", calls: []}])
    assert {:ok, prepared} = Adapter.prepare_configuration_request(native_request())
    command = %{type: :configure, command_id: prepared.command_id, changes: prepared.changes}
    before_records = Fixture.records(fixture, fixture.session)
    assert {:error, :attachment_required} = Loopex.command(nil, command)
    stale = %{fixture.attachment | incarnation_id: "stale-incarnation"}
    assert {:error, :session_unavailable} = Loopex.command(stale, command)
    assert Fixture.records(fixture, fixture.session) == before_records
    assert Agent.get(fixture.controller, & &1.calls) == 0

    assert {:accepted, "held-prompt"} =
             Loopex.command(fixture.attachment, %{
               type: :prompt,
               command_id: "held-prompt",
               content: "hold"
             })

    assert_receive {:holding, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:error, :configuration_not_settled} = Loopex.command(fixture.attachment, command)
    assert [refusal] = configuration_records(fixture)
    assert refusal.payload["command_id"] == command.command_id
    assert refusal.payload["changes"] == command.changes
    assert refusal.payload["admission"] == "rejected_configuration_not_settled"
    assert refusal.payload["configuration"] == nil
    assert Agent.get(fixture.controller, & &1.calls) == 0
    refute Enum.any?(Fixture.events(fixture, fixture.session), &(&1.kind == "session.configured"))
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000

    completion_cutoff = System.monotonic_time(:millisecond) + 5_000
    events = completed_events(fixture.attachment, completion_cutoff)

    assert Enum.any?(events, &(&1.kind == "run.finished"))
    terminal = Enum.find(events, &(&1.kind == "run.finished"))
    assert terminal["outcome"] == "completed"

    assert {:ok, status} = Loopex.session_status(fixture.runtime, fixture.session)
    assert status.configuration["configuration_version"] == 1
    assert status.configuration["model"] == "scripted:v1"
  end

  # Concept: worker cleanup precedes the serial owner's committed completion.
  # Technical depth: next_event can wait inside the runtime, so a monitored
  # reader spends one captured observer cutoff across reads, empty polls and its
  # normal join. Failure cleanup kills and joins that reader without a new read.
  defp completed_events(attachment, cutoff) do
    observer = self()

    {reader, monitor} =
      spawn_monitor(fn ->
        send(
          observer,
          {:configure_completion, self(), poll_completed_events(attachment, cutoff, [])}
        )
      end)

    on_exit(fn ->
      cleanup_monitor = Process.monitor(reader)
      if Process.alive?(reader), do: Process.exit(reader, :kill)
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^reader, _reason}, 1_000
    end)

    events =
      receive do
        {:configure_completion, ^reader, {:ok, events}} -> events
        {:configure_completion, ^reader, {:error, reason}} -> flunk(inspect(reason))
        {:DOWN, ^monitor, :process, ^reader, reason} -> flunk(inspect(reason))
      after
        max(cutoff - System.monotonic_time(:millisecond), 0) ->
          flunk("committed run.finished was not observed before the fixture cutoff")
      end

    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal},
                   max(cutoff - System.monotonic_time(:millisecond), 0)

    assert System.monotonic_time(:millisecond) <= cutoff
    events
  end

  defp poll_completed_events(attachment, cutoff, events) do
    if System.monotonic_time(:millisecond) >= cutoff do
      {:error, :completion_observation_cutoff}
    else
      case Loopex.next_event(attachment) do
        {:ok, %{kind: "run.finished"} = event} ->
          if System.monotonic_time(:millisecond) <= cutoff,
            do: {:ok, Enum.reverse([event | events])},
            else: {:error, :completion_observation_cutoff}

        {:ok, event} ->
          poll_completed_events(attachment, cutoff, [event | events])

        {:error, :empty} ->
          Process.sleep(min(10, max(cutoff - System.monotonic_time(:millisecond), 0)))
          poll_completed_events(attachment, cutoff, events)

        other ->
          {:error, {:completion_observation_failed, other}}
      end
    end
  end

  defp native_request do
    %{
      "method" => "session.configure",
      "request_id" => "configure",
      "command_id" => LoopexProtocol.Wire.encode_identity(<<0, 255, 1, 128>>),
      "changes" => %{
        "model" => " alias/model ",
        "reasoning" => "default",
        "instructions" => %{
          "version" => "wire.v1",
          "base" => "INGRESS_PRIVATE_INSTRUCTIONS 猫\n",
          "environment" => "captured environment",
          "appendix" => "exact tail"
        },
        "max_tokens" => "512",
        "context_token_budget" => "6000",
        "system_class_tokens" => "5000"
      }
    }
  end

  defp native_fixture(script \\ []) do
    {:ok, controller} = Agent.start_link(fn -> %{calls: 0, canonical: "scripted:v1"} end)
    model = Loopex.AgentLoopTestModel.start(script)
    executor = Loopex.AgentLoopTestExecutor.start()
    {store, handle} = Loopex.M1RuntimeTestStore.start_store(label: "configure-ingress")

    on_exit(fn ->
      for actor <- [controller, model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, 1_000
      end
    end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "configure-ingress",
        context_token_budget: 8_192,
        store: handle,
        session_creation_defaults: Fixture.creation_defaults([]),
        cleanup_grace_ms: 5_000,
        model: %{
          module: Preparing,
          model: "scripted:v1",
          options: [
            controller: controller,
            script: model,
            max_tokens: 256,
            private_canary: "INGRESS_HOST_OPTION"
          ]
        },
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tools: [],
        active_tools: [],
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "test", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    on_exit(fn ->
      runtime_monitor = Process.monitor(runtime.supervisor)
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      assert_receive {:DOWN, ^runtime_monitor, :process, _supervisor, _reason}, 5_000
    end)

    assert {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create")
    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    %{
      runtime: runtime,
      controller: controller,
      model: model,
      executor: executor,
      store: store,
      session: session,
      attachment: attachment
    }
  end

  defp configuration_records(fixture) do
    Enum.filter(
      Fixture.records(fixture, fixture.session),
      &(&1.payload.kind == "session_configuration_admitted_v2")
    )
  end

  defp request do
    Enum.find(vectors()["cases"], &(&1["name"] == "foreground-subset-63"))["input"]
  end

  defp vectors do
    JSON.decode!(
      File.read!(Path.join(:code.priv_dir(:loopex_protocol), "vectors/configure-request.v1.json"))
    )
  end
end

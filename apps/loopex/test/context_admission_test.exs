Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.ContextAdmissionTestModel do
  @moduledoc false

  @behaviour Loopex.Model

  def start(script, observer) do
    Agent.start_link(fn -> %{script: script, observer: observer, requests: []} end)
  end

  def requests(pid), do: Agent.get(pid, &Enum.reverse(&1.requests))

  @impl Loopex.Model
  def complete(request, options, _progress) do
    state = Keyword.fetch!(options, :state)

    {step, observer} =
      Agent.get_and_update(state, fn %{script: script} = current ->
        {step, rest} =
          case script do
            [next | tail] -> {next, tail}
            [] -> {%{text: "done"}, []}
          end

        {{step, current.observer},
         %{current | script: rest, requests: [request | current.requests]}}
      end)

    send(observer, {:context_model_invoked, self(), request})

    case Map.get(step, :hold) do
      true ->
        send(observer, {:context_model_holding, self()})

        receive do
          :release -> :ok
        after
          30_000 -> exit(:context_model_hold_timeout)
        end

      _other ->
        :ok
    end

    case Map.fetch(step, :error) do
      {:ok, reason} ->
        {:error, reason}

      :error ->
        reply = %{
          text: Map.get(step, :text, "done"),
          identity: %{provider: "fixture", model: request.model, endpoint: "in-process"},
          usage: Map.get(step, :usage, %{input_tokens: 3, output_tokens: 2}),
          tool_calls: Map.get(step, :tool_calls, []),
          delta_count: 0,
          streamed: false,
          canonical_request_bytes: request.canonical_request_bytes,
          staged_request_digest: request.staged_request_digest
        }

        {:ok, Map.merge(reply, Map.get(step, :reply_overrides, %{}))}
    end
  end
end

defmodule Loopex.ContextAdmissionTestPolicy do
  @moduledoc false

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(_request), do: {:allow, nil}
end

defmodule Loopex.ContextAdmissionTestExecutor do
  @moduledoc false

  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def execute(_reference, _job, _grant, _options, _progress),
    do: {:error, {:refused_before_effect, :no_context_test_tools}}

  @impl Loopex.Executor
  def cancel(_reference, _job_id), do: {:ok, :cleaned}
end

defmodule Loopex.ContextAdmissionPageOneStore do
  @moduledoc false

  @behaviour Loopex.Store

  alias Loopex.M1RuntimeTestStore

  @impl Loopex.Store
  def transact(reference, transaction),
    do: M1RuntimeTestStore.transact(reference.store, transaction)

  @impl Loopex.Store
  def transaction_status(reference, session_id, domain, tx_id),
    do: M1RuntimeTestStore.transaction_status(reference.store, session_id, domain, tx_id)

  @impl Loopex.Store
  def ownership_head(reference, session_id, domain),
    do: M1RuntimeTestStore.ownership_head(reference.store, session_id, domain)

  @impl Loopex.Store
  def runtime_command(reference, command),
    do: M1RuntimeTestStore.runtime_command(reference.store, command)

  @impl Loopex.Store
  def load_records(reference, session_id, after_version, _requested_limit) do
    maybe_block_after_page(reference, session_id, after_version)
    M1RuntimeTestStore.load_records(reference.store, session_id, after_version, 1)
  end

  @impl Loopex.Store
  def load_events(reference, session_id, after_sequence, _requested_limit),
    do: M1RuntimeTestStore.load_events(reference.store, session_id, after_sequence, 1)

  defp maybe_block_after_page(%{page_control: control, observer: observer}, session_id, version) do
    case Agent.get(control, & &1) do
      ^version ->
        token = make_ref()
        send(observer, {:context_page_boundary_held, self(), token, session_id, version})

        receive do
          {:release_context_page, ^token} -> :ok
        after
          30_000 -> exit(:context_page_boundary_timeout)
        end

      _other ->
        :ok
    end
  end
end

defmodule Loopex.ContextAdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Bitwise

  alias Loopex.Bounds
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Model
  alias Loopex.ProjectResource
  alias Loopex.Runtime
  alias Loopex.Runtime.ContextAdmission
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition

  @uint64_max 18_446_744_073_709_551_615
  @record_limit 65_536
  @max_item_depth 12
  @max_item_cardinality 1_024
  @reference_tool_definitions [
    %{
      "tool_id" => "loopex.read",
      "tool_version" => "1.0.0",
      "name" => "read",
      "description" =>
        "Read a UTF-8 text file beneath the workspace root. Returns bounded content and reports truncation.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path relative to the workspace root."
          }
        },
        "required" => ["path"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "File contents."},
      "effect_class" => "read_only",
      "idempotency_class" => "safe_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 65_536,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.write",
      "tool_version" => "1.0.0",
      "name" => "write",
      "description" =>
        "Create or replace a file beneath the workspace root with the exact content given.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path relative to the workspace root."
          },
          "content" => %{"type" => "string", "description" => "Exact bytes to write."}
        },
        "required" => ["path", "content"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What was written."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "safe_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 4_096,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.edit",
      "tool_version" => "1.0.0",
      "name" => "edit",
      "description" =>
        "Replace one exact occurrence of a string in a file. Fails and reports what it found if the match is absent or ambiguous.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path relative to the workspace root."
          },
          "old" => %{"type" => "string", "description" => "Exact text to replace."},
          "new" => %{"type" => "string", "description" => "Replacement text."}
        },
        "required" => ["path", "old", "new"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What changed."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "never_blind_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 4_096,
        "artifact_bytes" => 8_388_608
      }
    },
    %{
      "tool_id" => "loopex.bash",
      "tool_version" => "1.0.0",
      "name" => "bash",
      "description" =>
        "Run a command in the workspace. Supply argv for no shell interpretation, or command for an explicit shell.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "argv" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Program and arguments, run without a shell."
          },
          "command" => %{
            "type" => "string",
            "description" => "A raw shell command, interpreted by the shell."
          }
        },
        "required" => []
      },
      "result_shape" => %{"content_type" => "text", "description" => "Combined output."},
      "effect_class" => "process",
      "idempotency_class" => "never_blind_retry",
      "budgets" => %{
        "wall_time_ms" => 120_000,
        "output_bytes" => 65_536,
        "artifact_bytes" => 8_388_608
      }
    }
  ]
  @context_receipt_keys ~w(
    blocks context_record_byte_ceiling context_token_budget
    descriptor_canonicalization_version ordered_descriptor_digest
    project_resource provider_estimated_tokens provider_identity provider_revision
    record_byte_cost selector_identity selector_revision token_estimator totals
    transformer_identity transformer_revision
  )

  test "Runtime rejects an omitted or invalid context token budget before Control or Store starts" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "context-validation")
    on_exit(fn -> stop_process(store_pid) end)
    {:module, Loopex.Runtime.Control} = Code.ensure_loaded(Loopex.Runtime.Control)

    assert :erlang.trace_pattern(
             {Loopex.Runtime.Control, :start_link, 1},
             true,
             [:local]
           ) == 1

    :erlang.trace(self(), true, [:call, :set_on_spawn])

    on_exit(fn ->
      _ = :erlang.trace(self(), false, [:call, :set_on_spawn])
      _ = :erlang.trace_pattern({Loopex.Runtime.Control, :start_link, 1}, false, [:local])
    end)

    base = [runtime_id: "context-validation", store: store]

    for {label, options} <- [
          {:omitted, base},
          {:zero, Keyword.put(base, :context_token_budget, 0)},
          {:negative, Keyword.put(base, :context_token_budget, -1)},
          {:non_integer, Keyword.put(base, :context_token_budget, "8192")},
          {:overflow, Keyword.put(base, :context_token_budget, @uint64_max + 1)}
        ] do
      result = Loopex.start_link(options)
      if match?({:ok, _runtime}, result), do: result |> elem(1) |> Loopex.stop()

      assert result == {:error, :invalid_context_token_budget},
             "#{label} context configuration returned #{inspect(result)}"

      assert M1RuntimeTestStore.inspect_state(store_pid).sessions == %{},
             "#{label} context configuration reached Store"

      refute_receive {:trace, _pid, :call, {Loopex.Runtime.Control, :start_link, _arguments}},
                     0,
                     "#{label} context configuration started Runtime Control before validation"
    end
  end

  test "live required context commits every exact first failure and dispatches no provider" do
    fixture = start_fixture(context_token_budget: 8_192, script: [%{text: "unreachable"}])
    store_before = M1RuntimeTestStore.inspect_state(fixture.store)
    requests_before = Loopex.ContextAdmissionTestModel.requests(fixture.model)

    # Concept: these candidate oracles lock the Store-owned ordering and exact
    # dimension relations. They are not proof that the live coordinator commits
    # each refusal; the live context-token path below supplies that end-to-end
    # Store/reducer proof, while the remaining live dimensions require inputs
    # capable of making the fixed required system and closed tool shapes reach
    # those boundaries.
    #
    # Technical depth: the depth case is deliberately first so the opening gate
    # is red for the absent ContextAdmission boundary itself. Its candidate is
    # already in Store-normalized key form and reaches the first rejected node,
    # thirteen, while every token guard is below its limit. Directly exercising
    # this reversible internal boundary does not fabricate a facade result or
    # add a test-only callback to the coordinator.
    cases = [
      {"context_record_depth",
       fn ->
         required_context_candidate(nested_value(@max_item_depth))
       end, %{system_class_tokens: 0, provider_estimated_tokens: 0, context_token_budget: 8_192},
       @max_item_depth + 1, @max_item_depth, nil},
      {"system_class_tokens", fn -> required_context_candidate("system") end,
       %{
         system_class_tokens: 1_000,
         provider_estimated_tokens: 1_000,
         context_token_budget: 8_192
       }, 1_000, 1_000, nil},
      {"context_tokens", fn -> required_context_candidate("total") end,
       %{system_class_tokens: 1, provider_estimated_tokens: 2, context_token_budget: 1}, 2, 1,
       nil},
      {"context_record_cardinality",
       fn -> required_context_candidate(Enum.to_list(1..(@max_item_cardinality + 1))) end,
       %{system_class_tokens: 0, provider_estimated_tokens: 0, context_token_budget: 8_192},
       @max_item_cardinality + 1, @max_item_cardinality, nil},
      {"context_record_bytes", fn -> sized_context_candidate(@record_limit + 1) end,
       %{system_class_tokens: 0, provider_estimated_tokens: 0, context_token_budget: 8_192},
       @record_limit + 1, @record_limit, @record_limit + 1}
    ]

    for {dimension, candidate_builder, token_observations, observed, limit, record_byte_cost} <-
          cases do
      candidate = candidate_builder.()

      assert {:refused,
              %{
                "dimension" => ^dimension,
                "observed" => ^observed,
                "limit" => ^limit,
                "record_byte_cost" => ^record_byte_cost
              }} =
               dynamic_apply(ContextAdmission, :preflight_required_candidate, [
                 candidate,
                 Map.merge(token_observations, %{
                   context_record_byte_ceiling: @record_limit,
                   context_record_depth_limit: @max_item_depth,
                   context_record_cardinality_limit: @max_item_cardinality
                 })
               ])
    end

    assert dynamic_apply(Store, :max_item_bytes, []) == @record_limit
    assert M1RuntimeTestStore.inspect_state(fixture.store) == store_before
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == requests_before

    live = start_fixture(context_token_budget: 1, script: [%{text: "must not dispatch"}])
    {session_id, attachment} = create_attached_session(live)

    assert {:accepted, "live-context-first-failure"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "live-context-first-failure",
               content: "required context exceeds the committed total"
             })

    assert await_event(attachment, "run.finished")["failure"]["dimension"] == "context_tokens"
    assert Loopex.ContextAdmissionTestModel.requests(live.model) == []

    assert Enum.map(
             Enum.filter(records(live, session_id), fn record ->
               record_kind(record) in ["context_admission_refused_v1", "run_terminal_committed"]
             end),
             &record_kind/1
           ) == ["context_admission_refused_v1", "run_terminal_committed"]
  end

  test "a dead preparer makes real Core abandonment unconfirmed without activation or dispatch" do
    fixture =
      start_fixture(
        context_token_budget: 321,
        script: [%{text: "held", hold: true}, %{text: "must not be redispatched"}]
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "owner-unconfirmed"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "owner-unconfirmed",
               content: "hold"
             })

    assert_receive {:context_model_holding, _worker}, 5_000
    coordinator = coordinator_of(fixture.runtime)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000

    parent = self()

    {preparer, preparer_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:short_lived_preparation,
           dynamic_apply(Loopex, :prepare_resume_session, [
             fixture.runtime,
             session_id,
             "short-lived-context-owner"
           ])}
        )
      end)

    assert_receive {:short_lived_preparation, {:ok, {:prepared, activation}}}, 5_000
    assert_receive {:DOWN, ^preparer_monitor, :process, ^preparer, :normal}, 5_000

    requests_before = Loopex.ContextAdmissionTestModel.requests(fixture.model)

    assert {:error, abandon_reason} = dynamic_apply(Loopex, :abandon_resume, [activation])
    refute abandon_reason in [nil, :ok]
    assert {:error, _not_activatable} = dynamic_apply(Loopex, :activate_resume, [activation])
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == requests_before
  end

  test "command admission preflights every durable candidate and refuses an unrepresentable future terminal before work" do
    fixture = start_fixture(context_token_budget: 8_192, script: [%{text: "held", hold: true}])
    {session_id, attachment} = create_attached_session(fixture)

    # One copy of this integer fits the command record; the two exact bound
    # observations in its future terminal do not. The refusal must therefore be
    # about the first future durable candidate, not content or configuration.
    large_but_admissible_command_value = 1 <<< 320_000

    max_turns_command = %{
      type: :prompt,
      command_id: "future-terminal-too-large",
      content: "do not dispatch",
      bounds: %{
        max_turns: large_but_admissible_command_value,
        token_budget: 1_000,
        deadline_ms: 60_000
      }
    }

    max_turns_refusal = Loopex.command(attachment, max_turns_command)

    assert {:error,
            {:command_admission_too_large, "future_bound_record_bytes",
             "max_turns_private_terminal", observed, @record_limit}} = max_turns_refusal

    assert observed > @record_limit
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == []

    # Exact replay is resolved from retained command truth before the now-active
    # run and its queues are consulted. Changed normalized input conflicts.
    assert ^max_turns_refusal = Loopex.command(attachment, max_turns_command)

    assert {:accepted, "admitted-after-refusal"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "admitted-after-refusal",
               content: "hold an active run"
             })

    assert_receive {:context_model_holding, model_worker}, 5_000
    assert ^max_turns_refusal = Loopex.command(attachment, max_turns_command)

    assert {:error, :idempotency_conflict} =
             Loopex.command(attachment, %{max_turns_command | content: "changed input"})

    {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)
    oversized_content = String.duplicate("x", @record_limit + 1)

    steer = %{
      type: :steer,
      command_id: "oversized-steer",
      run_id: run_id,
      content: oversized_content
    }

    follow_up = %{
      type: :follow_up,
      command_id: "oversized-follow-up",
      content: oversized_content
    }

    steer_refusal = Loopex.command(attachment, steer)

    assert {:error,
            {:command_admission_too_large, "command_record_bytes", "steer_record", steer_observed,
             @record_limit}} = steer_refusal

    assert steer_observed > @record_limit

    follow_up_refusal = Loopex.command(attachment, follow_up)

    assert {:error,
            {:command_admission_too_large, "command_record_bytes", "follow_up_record",
             follow_up_observed, @record_limit}} = follow_up_refusal

    assert follow_up_observed > @record_limit

    assert {:accepted, "small-steer"} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "small-steer",
               run_id: run_id,
               content: "small"
             })

    assert {:accepted, "small-follow-up"} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "small-follow-up",
               content: "small successor"
             })

    assert steer_refusal == Loopex.command(attachment, steer)
    assert follow_up_refusal == Loopex.command(attachment, follow_up)

    assert {:error, :idempotency_conflict} =
             Loopex.command(attachment, %{steer | content: oversized_content <> "!"})

    assert {:error, :idempotency_conflict} =
             Loopex.command(attachment, %{follow_up | content: oversized_content <> "!"})

    records = records(fixture, session_id)
    refusals = Enum.filter(records, &kind?(&1, "command_admission_refused_v1"))
    assert length(refusals) == 3
    [refusal | _rest] = refusals

    assert refusal.payload["dimension"] == "future_bound_record_bytes"
    assert refusal.payload["candidate"] == "max_turns_private_terminal"
    assert Enum.all?(refusals, &(Enum.sort(Map.keys(&1.payload)) == command_refusal_keys()))
    refute Enum.any?(refusals, &Map.has_key?(&1.payload, "content"))

    refute Enum.any?(events(fixture, session_id), fn event ->
             event["command_id"] in [
               "future-terminal-too-large",
               "oversized-steer",
               "oversized-follow-up"
             ]
           end)

    send(model_worker, :release)

    token_fixture = start_fixture(context_token_budget: 8_192, script: [%{text: "unreachable"}])
    {_token_session, token_attachment} = create_attached_session(token_fixture)

    assert {:error,
            {:command_admission_too_large, "future_bound_record_bytes",
             "token_budget_private_terminal", token_observed, @record_limit}} =
             Loopex.command(token_attachment, %{
               type: :prompt,
               command_id: "future-token-terminal-too-large",
               content: "do not dispatch",
               bounds: %{
                 max_turns: 8,
                 token_budget: large_but_admissible_command_value,
                 deadline_ms: 60_000
               }
             })

    assert token_observed > @record_limit
    assert Loopex.ContextAdmissionTestModel.requests(token_fixture.model) == []

    deadline_fixture = start_fixture(context_token_budget: 8_192, script: [%{text: "done"}])
    {deadline_session, deadline_attachment} = create_attached_session(deadline_fixture)

    before_staging = System.system_time(:millisecond)

    assert {:accepted, "deadline-shape"} =
             Loopex.command(deadline_attachment, %{
               type: :prompt,
               command_id: "deadline-shape",
               content: "stage a deadline",
               bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: 60_000}
             })

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert request.deadline >= before_staging + 59_000

    deadline_records = records(deadline_fixture, deadline_session)
    assert Enum.any?(deadline_records, &kind?(&1, "prompt_admitted_v2"))
  end

  test "deadline staging checks clock domain and absolute uint64 addition before dispatch and replays one exact pair" do
    safe_duration = @uint64_max - System.system_time(:millisecond) - 60_000
    safe = start_fixture(context_token_budget: 8_192, script: [%{text: "safe deadline"}])
    {_safe_session, safe_attachment} = create_attached_session(safe)

    assert {:accepted, "safe-uint64-deadline"} =
             Loopex.command(safe_attachment, %{
               type: :prompt,
               command_id: "safe-uint64-deadline",
               content: "stage without wrapping",
               bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: safe_duration}
             })

    assert_receive {:context_model_invoked, _worker, safe_request}, 5_000
    assert safe_request.deadline <= @uint64_max
    assert safe_request.deadline >= @uint64_max - 60_000

    overflow =
      start_fixture(context_token_budget: 8_192, script: [%{text: "must not dispatch"}])

    {session_id, attachment} = create_attached_session(overflow)

    assert {:accepted, "overflow-uint64-deadline"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "overflow-uint64-deadline",
               content: "refuse before opening an attempt",
               bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: @uint64_max}
             })

    finished = await_event(attachment, "run.finished")
    assert finished["outcome"] == "failed"
    assert finished["failure"]["category"] == "deadline_preflight_failed"
    assert finished["failure"]["retryable"] == false
    assert Loopex.ContextAdmissionTestModel.requests(overflow.model) == []

    all_records = records(overflow, session_id)

    [failure, terminal] =
      Enum.filter(all_records, fn record ->
        record_kind(record) in ["deadline_staging_failed_v1", "run_terminal_committed"]
      end)

    assert failure.payload == %{
             "run_id" => failure.payload["run_id"],
             "turn_id" => failure.payload["turn_id"],
             "category" => "deadline_addition_overflow",
             kind: "deadline_staging_failed_v1"
           }

    assert terminal.journal_version == failure.journal_version + 1
    assert terminal.payload["run_id"] == failure.payload["run_id"]
    assert terminal.payload["failure"] == finished["failure"]

    assert {:ok, recovered} =
             SessionState.recover(session_id, all_records, events(overflow, session_id))

    assert recovered.active_run_id == nil

    failure_index = Enum.find_index(all_records, &kind?(&1, "deadline_staging_failed_v1"))
    terminal_index = failure_index + 1

    for {label, malformed} <- [
          {:missing_tail, List.delete_at(all_records, terminal_index)},
          {:duplicate_first, List.insert_at(all_records, terminal_index, failure)},
          {:intervening,
           List.insert_at(all_records, terminal_index, %{
             failure
             | payload: %{kind: "unexpected_intervening"}
           })},
          {:mismatched_run,
           List.update_at(all_records, terminal_index, fn row ->
             put_in(row, [:payload, "run_id"], "r_other")
           end)}
        ] do
      assert {:error, _reason} =
               SessionState.recover(session_id, malformed, events(overflow, session_id)),
             "#{label} deadline pair replayed"
    end
  end

  test "prompt steer and follow-up refusal commit-unknown re-present one exact command binding" do
    oversized_content = String.duplicate("x", @record_limit + 1)

    for command_type <- [:prompt, :steer, :follow_up] do
      fixture =
        start_fixture(
          context_token_budget: 8_192,
          script: [%{text: "held", hold: true}]
        )

      {session_id, attachment} = create_attached_session(fixture)

      {command, held_worker} =
        case command_type do
          :prompt ->
            {%{
               type: :prompt,
               command_id: "unknown-prompt",
               content: oversized_content
             }, nil}

          queued_type ->
            hold_command_id = "hold-for-#{queued_type}"

            assert {:accepted, ^hold_command_id} =
                     Loopex.command(attachment, %{
                       type: :prompt,
                       command_id: hold_command_id,
                       content: "hold"
                     })

            assert_receive {:context_model_holding, worker}, 5_000

            assert {:ok, %{active_run_id: run_id}} =
                     Loopex.session_status(fixture.runtime, session_id)

            command = %{
              type: queued_type,
              command_id: "unknown-#{queued_type}",
              content: oversized_content
            }

            command =
              if queued_type == :steer, do: Map.put(command, :run_id, run_id), else: command

            {command, worker}
        end

      requests_before = Loopex.ContextAdmissionTestModel.requests(fixture.model)
      :erlang.trace(fixture.store, true, [:receive])

      :ok =
        M1RuntimeTestStore.inject(
          fixture.store,
          {:session_journal_commit, :after_linearization_before_result}
        )

      candidate = "#{command_type}_record"

      assert {:error,
              {:command_admission_too_large, "command_record_bytes", ^candidate, observed,
               @record_limit}} = Loopex.command(attachment, command)

      assert observed > @record_limit

      presentations =
        fixture.store
        |> traced_transactions()
        |> Enum.filter(fn transaction ->
          Enum.any?(transaction.records, fn record ->
            record_kind(record) == "command_admission_refused_v1" and
              record["command_id"] == command.command_id
          end)
        end)

      assert [first, second | _rest] = presentations
      assert first == second

      [retained] =
        fixture
        |> records(session_id)
        |> Enum.filter(fn record ->
          kind?(record, "command_admission_refused_v1") and
            record.payload["command_id"] == command.command_id
        end)

      assert retained.payload["candidate"] == candidate

      [refusal | rest] = first.records
      changed_refusal = Map.update!(refusal, "observed", &(&1 + 1))

      assert {:ok, changed_binding} =
               Store.session_commit(
                 first.session_id,
                 first.mutation_domain,
                 first.tx_id,
                 first.expected_owner_epoch,
                 first.expected_owner_incarnation_id,
                 first.expected_journal_version,
                 [changed_refusal | rest],
                 first.outbox
               )

      assert {:not_committed, :tx_id_conflict} =
               Store.transact(fixture.store_handle, changed_binding)

      assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == requests_before

      refute Enum.any?(events(fixture, session_id), fn event ->
               event["command_id"] == command.command_id
             end)

      if held_worker, do: send(held_worker, :release)
    end
  end

  test "the named reference fixture binds exact context definition-list retained-component and receipt fixed point" do
    definitions = @reference_tool_definitions

    fixture =
      start_fixture(
        context_token_budget: 8_192,
        script: [%{text: "done"}],
        tools: definitions
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "fixed-point"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "fixed-point",
               content: "measure once"
             })

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    [system_message | _session_messages] = request.messages
    provider_members = [system_message | Model.model_facing_tools(request)]

    provider_bytes =
      provider_members
      |> Enum.map(&Canonical.encode/1)
      |> Enum.sum_by(&byte_size/1)

    provider_tokens =
      provider_members
      |> Enum.map(&Canonical.encode/1)
      |> Enum.sum_by(&Bounds.estimate/1)

    assert provider_bytes == 2_393
    assert provider_tokens == 799

    retained_components =
      [
        Canonical.encode(system_message)
        | Enum.map(definitions, &ToolDefinition.canonical_bytes/1)
      ]

    assert Enum.sum_by(retained_components, &byte_size/1) == 4_382
    assert Enum.sum_by(retained_components, &Bounds.estimate/1) == 1_462

    project_message = %{
      "role" => "user",
      "content" =>
        "<project_resource label=\"AGENTS.md\">\n" <>
          String.duplicate("x", @record_limit) <> "\n</project_resource>"
    }

    project_bytes = Canonical.encode(project_message)
    assert byte_size(project_bytes) == 65_653
    assert Bounds.estimate(project_bytes) == 21_885

    [committed] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "model_request_committed"))

    receipt = committed.payload["context_receipt"]
    assert Enum.sort(Map.keys(receipt)) == Enum.sort(@context_receipt_keys)

    assert {:ok, normalized, measured} =
             dynamic_apply(Store, :normalize_and_measure_item, [:record, committed.payload])

    assert normalized == committed.payload
    assert receipt["record_byte_cost"] == measured
    assert measured <= @record_limit
    assert receipt["token_estimator"] == "loopex.context_bytes.v1"
    refute receipt["token_estimator"] == "loopex.conservative_bytes.v1"
    assert receipt["provider_identity"] == "loopex.context.reference"
    assert receipt["provider_revision"] == 2
    assert {receipt["transformer_identity"], receipt["transformer_revision"]} == {nil, nil}
    assert {receipt["selector_identity"], receipt["selector_revision"]} == {nil, nil}

    assert receipt["project_resource"] == %{
             "class" => "project_resource",
             "receipt_revision" => 2,
             "disposition" => "no_manifest",
             "detail" => %{}
           }

    assert {fixed_record, ^measured} = resolve_record_cost(committed.payload)
    assert fixed_record == committed.payload

    canonical_definition_list = Canonical.encode(definitions)
    assert byte_size(canonical_definition_list) == 3_530
    assert Bounds.estimate(canonical_definition_list) == 1_177

    assert Enum.map(definitions, &ToolDefinition.generation/1) ==
             Enum.map(request.tools, &ToolDefinition.generation/1)

    malformed_project_receipt_records =
      Enum.map(records(fixture, session_id), fn
        %{payload: %{kind: "model_request_committed"} = payload} = record ->
          malformed_project =
            payload
            |> get_in(["context_receipt", "project_resource"])
            |> Map.update!("detail", &Map.put(&1, "unexpected", true))

          %{
            record
            | payload: put_in(payload, ["context_receipt", "project_resource"], malformed_project)
          }

        record ->
          record
      end)

    assert {:error, _malformed_compact_project_receipt} =
             SessionState.recover(
               session_id,
               malformed_project_receipt_records,
               events(fixture, session_id)
             )

    before_recovery = committed.payload
    :ok = Loopex.stop(fixture.runtime)

    replacement = restart_fixture(fixture)

    assert {:ok, ^session_id} =
             Loopex.resume_session(replacement, session_id, command_id: "resume")

    [replayed] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "model_request_committed"))

    assert replayed.payload == before_recovery
  end

  test "optional project stages empty or is wholly withheld and recomputed by token or record budget" do
    empty_manifest = %{entries: [], workspace: project_workspace()}
    empty = run_project_stage("empty-project", empty_manifest, 8_192)

    assert empty.project == %{
             "class" => "project_resource",
             "receipt_revision" => 2,
             "disposition" => "staged",
             "detail" => %{
               "manifest_digest" => empty.manifest_digest,
               "decision_source" => "host_supplied",
               "workspace_ref" => "workspace-ref",
               "entries" => []
             }
           }

    assert project_messages(empty.request) == []
    assert project_bucket(empty.receipt) == %{"byte_cost" => 0, "token_cost" => 0}

    token_manifest = %{
      entries: [project_entry(String.duplicate("t", 30_000))],
      workspace: project_workspace()
    }

    token = run_project_stage("token-withheld-project", token_manifest, 2_000)

    assert token.project["disposition"] == "context_token_budget"
    assert token.project["detail"]["dimension"] == "context_tokens"
    assert token.project["detail"]["limit"] == 2_000
    assert token.project["detail"]["observed"] > token.project["detail"]["limit"]
    assert token.receipt["provider_estimated_tokens"] <= 2_000
    assert project_messages(token.request) == []
    assert project_bucket(token.receipt) == %{"byte_cost" => 0, "token_cost" => 0}

    record_manifest = %{
      entries: [project_entry(String.duplicate("r", 64_000))],
      workspace: project_workspace()
    }

    record = run_project_stage("record-withheld-project", record_manifest, @uint64_max)

    assert record.project["disposition"] == "context_record_bytes"
    assert record.project["detail"]["dimension"] == "context_record_bytes"
    assert record.project["detail"]["limit"] == @record_limit
    assert record.project["detail"]["observed"] > @record_limit
    assert record.receipt["record_byte_cost"] <= @record_limit
    assert project_messages(record.request) == []
    assert project_bucket(record.receipt) == %{"byte_cost" => 0, "token_cost" => 0}

    for staged <- [empty, token, record] do
      assert {fixed, measured} = resolve_record_cost(staged.committed)
      assert fixed == staged.committed
      assert measured == staged.receipt["record_byte_cost"]
    end
  end

  # Concept: a refusal has to describe the request that was actually refused.
  #
  # Technical depth: ADR 0017 gives the compact refusal exactly four counts --
  # system, session, steer, tool -- and states that they partition the exact
  # sequence whose bytes determine `provider_estimated_tokens` and
  # `ordered_descriptor_digest`, and that all four plus the digest describe the
  # required-only set fixed at evaluation step 2. There is no count for an
  # optional project descriptor, so a candidate carrying one is not describable
  # by this record at all. The reducer cannot catch that later: recovery retains
  # no descriptor bodies, so it can only check count domains and the
  # per-dimension relations. The live constructor holds the preimage, so it is
  # the boundary that has to prove the partition.
  test "the live constructor never describes a project-bearing candidate as a required-only refusal" do
    manifest = %{
      entries: [project_entry(String.duplicate("p", 4_000))],
      workspace: project_workspace()
    }

    {:ok, manifest_digest, _entries} = ProjectResource.digest(manifest)

    with_project =
      staged_candidate("partition-with-project",
        project_manifest: manifest,
        project_decision: project_decision(manifest_digest)
      )

    assert Enum.count(
             with_project.receipt["blocks"],
             &(&1["provenance_class"] == "project_resource")
           ) == 1

    over_budget = put_in(with_project.receipt, ["context_token_budget"], 1)

    assert {:refused_not_required_only, %{"dimension" => "context_tokens"}} =
             SessionState.propose_model_request(
               with_project.state,
               with_project.run_id,
               with_project.request,
               context_receipt: over_budget
             )

    padded =
      update_in(with_project.receipt, ["blocks"], fn [first | _rest] = blocks ->
        blocks ++ List.duplicate(first, @max_item_cardinality + 1 - length(blocks))
      end)

    assert length(padded["blocks"]) == @max_item_cardinality + 1

    assert {:refused_not_required_only,
            %{"dimension" => "context_record_cardinality", "observed" => 1_025}} =
             SessionState.propose_model_request(
               with_project.state,
               with_project.run_id,
               with_project.request,
               context_receipt: padded
             )

    # Technical depth: the same boundary, handed the required-only sequence,
    # produces the compact record and its four counts add up to exactly the
    # descriptor list behind the retained digest and estimated-token total.
    required_only = staged_candidate("partition-required-only", [])

    blocks = required_only.receipt["blocks"]
    assert Enum.all?(blocks, &(&1["provenance_class"] != "project_resource"))
    assert required_only.receipt["ordered_descriptor_digest"] == descriptor_digest(blocks)

    assert {:refused, compact} =
             SessionState.propose_model_request(
               required_only.state,
               required_only.run_id,
               required_only.request,
               context_receipt: put_in(required_only.receipt, ["context_token_budget"], 1)
             )

    assert compact["system_message_count"] + compact["session_message_count"] +
             compact["steer_message_count"] + compact["tool_definition_count"] == length(blocks)

    assert compact["ordered_descriptor_digest"] ==
             required_only.receipt["ordered_descriptor_digest"]

    assert compact["provider_estimated_tokens"] ==
             required_only.receipt["provider_estimated_tokens"]

    assert compact["project_disposition"] == "no_manifest"
  end

  # Concept: an optional project that was never weighed is not charged for a
  # failure it had no part in.
  #
  # Technical depth: the strict `system` class ceiling is decided over required
  # content alone, so ADR 0017 evaluation step 3 reaches it before the optional
  # class is added at step 6. The retained refusal therefore carries the
  # required-only estimate and counts -- identical to the same request staged
  # with no manifest at all -- and `not_evaluated_required_failure` is a true
  # statement rather than a label on a project that was already staged, measured
  # and charged. The control staging proves the withheld class was not empty.
  test "a system class refusal beside a staged project retains the required-only estimate" do
    manifest = %{
      entries: [project_entry(String.duplicate("q", 4_000))],
      workspace: project_workspace()
    }

    {:ok, manifest_digest, _entries} = ProjectResource.digest(manifest)
    tools = @reference_tool_definitions ++ [padded_tool_definition()]

    with_project =
      system_class_refusal("system-class-with-project", tools,
        project_manifest: manifest,
        project_decision: project_decision(manifest_digest)
      )

    without_project = system_class_refusal("system-class-without-project", tools, [])

    for observed <- [with_project, without_project] do
      assert observed.failure == %{
               "category" => "context_budget_exceeded",
               "retryable" => false,
               "dimension" => "system_class_tokens",
               "observed" => with_project.failure["observed"],
               "limit" => 1_000
             }

      assert observed.refusal["system_message_count"] == 1
      assert observed.refusal["session_message_count"] == 1
      assert observed.refusal["steer_message_count"] == 0
      assert observed.refusal["tool_definition_count"] == length(tools)

      assert observed.refusal["system_message_count"] + observed.refusal["session_message_count"] +
               observed.refusal["steer_message_count"] +
               observed.refusal["tool_definition_count"] == length(tools) + 2
    end

    assert with_project.refusal["provider_estimated_tokens"] ==
             without_project.refusal["provider_estimated_tokens"]

    assert with_project.refusal["project_disposition"] == "not_evaluated_required_failure"
    assert without_project.refusal["project_disposition"] == "no_manifest"

    control = run_project_stage("system-class-control", manifest, @uint64_max)
    assert control.project["disposition"] == "staged"
    assert project_bucket(control.receipt)["token_cost"] > 0
  end

  # Technical depth: the fixed-point resolution is skipped only for a
  # structurally inadmissible candidate, which is then named by its own
  # structural dimension instead of being carried forward with an unresolved
  # self-size. Every other resolution failure is returned unchanged.
  test "a structurally inadmissible candidate is still named by its structural dimension" do
    required_only = staged_candidate("structural-dimension", [])

    nested =
      update_in(required_only.receipt, ["blocks"], fn [first | rest] ->
        [Map.put(first, "source_reference", nested_value(@max_item_depth - 3)) | rest]
      end)

    assert {:refused, %{"dimension" => "context_record_depth", "record_byte_cost" => nil}} =
             SessionState.propose_model_request(
               required_only.state,
               required_only.run_id,
               required_only.request,
               context_receipt: nested
             )
  end

  test "structured source goldens receipt arithmetic digest framing and malformed replay form one locked matrix" do
    for {source_reference, canonical_hex, digest} <- source_reference_goldens() do
      bytes = Canonical.encode(source_reference)
      assert Base.encode16(bytes, case: :lower) == canonical_hex
      assert Canonical.digest_bytes(bytes) == digest
    end

    fixture =
      start_fixture(
        context_token_budget: 8_192,
        script: [%{text: "done"}],
        tools: @reference_tool_definitions
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "receipt-matrix"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "receipt-matrix",
               content: "bind every receipt relation"
             })

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    [committed] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "model_request_committed"))

    receipt = committed.payload["context_receipt"]
    blocks = receipt["blocks"]

    assert Enum.sort(Map.keys(receipt)) == Enum.sort(@context_receipt_keys)

    assert Enum.all?(blocks, fn block ->
             Enum.sort(Map.keys(block)) ==
               ~w(byte_cost content_digest provenance_class source_reference token_cost trust_class)
           end)

    totals = receipt["totals"]
    assert Enum.sort(Map.keys(totals)) == Enum.sort(~w(by_provenance byte_cost token_cost))
    assert Enum.sort(Map.keys(totals["by_provenance"])) == ~w(project_resource session system)

    assert totals["byte_cost"] == Enum.sum(Enum.map(blocks, & &1["byte_cost"]))
    assert totals["token_cost"] == Enum.sum(Enum.map(blocks, & &1["token_cost"]))
    assert receipt["provider_estimated_tokens"] == totals["token_cost"]

    for provenance <- ~w(system session project_resource) do
      bucket = totals["by_provenance"][provenance]
      selected = Enum.filter(blocks, &(&1["provenance_class"] == provenance))
      assert Enum.sort(Map.keys(bucket)) == ~w(byte_cost token_cost)
      assert bucket["byte_cost"] == Enum.sum(Enum.map(selected, & &1["byte_cost"]))
      assert bucket["token_cost"] == Enum.sum(Enum.map(selected, & &1["token_cost"]))
    end

    assert receipt["ordered_descriptor_digest"] == descriptor_digest(blocks)

    provider_members = request.messages ++ Model.model_facing_tools(request)

    assert length(blocks) == length(provider_members)

    Enum.zip(blocks, provider_members)
    |> Enum.each(fn {block, member} ->
      encoded = Canonical.encode(member)
      assert block["byte_cost"] == byte_size(encoded)
      assert block["token_cost"] == Bounds.estimate(encoded)
      assert block["content_digest"] == Canonical.digest_bytes(encoded)
    end)

    [system_message | _rest] = request.messages
    system_members = [system_message | Model.model_facing_tools(request)]

    system_bytes =
      system_members
      |> Enum.map(&Canonical.encode/1)
      |> Enum.sum_by(&byte_size/1)

    system_tokens =
      system_members
      |> Enum.map(&Canonical.encode/1)
      |> Enum.sum_by(&Bounds.estimate/1)

    assert totals["by_provenance"]["system"] == %{
             "byte_cost" => system_bytes,
             "token_cost" => system_tokens
           }

    assert receipt["provider_estimated_tokens"] ==
             provider_members
             |> Enum.map(&Canonical.encode/1)
             |> Enum.sum_by(&Bounds.estimate/1)

    base_records = records(fixture, session_id)
    base_events = events(fixture, session_id)

    # Concept: every refusal below is a negative. Without this anchor a corpus that
    # replays for no reason at all would satisfy all of them, so the baseline is the
    # assertion that gives the mutations their meaning.
    assert {:ok, _baseline} = SessionState.recover(session_id, base_records, base_events),
           "the unmutated corpus must replay before a mutation can prove refusal"

    mutations = [
      {:scalar_reference, fn _reference -> "system:loopex.system.v1" end},
      {:missing_member, &Map.delete(&1, "kind")},
      {:unknown_member, &Map.put(&1, "unexpected", true)},
      {:cross_kind_member, &Map.put(&1, "tool_id", "fixture.read")},
      {:kind_substitution, &Map.put(&1, "kind", "session_command")}
    ]

    for {label, mutate} <- mutations do
      malformed =
        mutate_model_request(base_records, fn payload ->
          update_in(payload, ["context_receipt", "blocks"], fn [first | rest] ->
            [Map.update!(first, "source_reference", mutate) | rest]
          end)
        end)

      assert {:error, _reason} = SessionState.recover(session_id, malformed, base_events),
             "#{label} source reference replayed"
    end

    for {label, mutate} <- [
          {:descriptor_reorder,
           fn payload ->
             update_in(payload, ["context_receipt", "blocks"], &Enum.reverse/1)
           end},
          {:unknown_canonical_version,
           fn payload ->
             put_in(
               payload,
               ["context_receipt", "descriptor_canonicalization_version"],
               "loopex.canonical.unknown"
             )
           end},
          {:message_substitution,
           fn payload ->
             update_in(payload, ["request", "messages"], fn [first | rest] ->
               [Map.put(first, "content", "substituted") | rest]
             end)
           end}
        ] do
      malformed = mutate_model_request(base_records, mutate)

      assert {:error, _reason} = SessionState.recover(session_id, malformed, base_events),
             "#{label} receipt replayed"
    end
  end

  test "self consistent message tool and project substitutions cannot outrun adjacent receipt relations" do
    manifest = %{
      entries: [project_entry("adjacent project context")],
      workspace: project_workspace()
    }

    {:ok, manifest_digest, _entries} = ProjectResource.digest(manifest)

    fixture =
      start_fixture(
        context_token_budget: 8_192,
        script: [%{text: "done"}],
        tools: @reference_tool_definitions,
        project_manifest: manifest,
        project_decision: project_decision(manifest_digest)
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "adjacent-relations"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "adjacent-relations",
               content: "bind adjacent context relations"
             })

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    record_prefix = records_through_kind(records(fixture, session_id), "model_request_committed")

    event_prefix =
      recoverable_event_prefix(session_id, record_prefix, events(fixture, session_id))

    assert {:ok, _baseline} = SessionState.recover(session_id, record_prefix, event_prefix)

    request_mutations = [
      {:system_message,
       fn staged ->
         %{staged | messages: replace_message(staged.messages, &(&1["role"] == "system"))}
       end},
      {:session_message,
       fn staged ->
         %{
           staged
           | messages:
               replace_message(
                 staged.messages,
                 &(&1["content"] == "bind adjacent context relations")
               )
         }
       end},
      {:project_message,
       fn staged ->
         %{staged | messages: replace_message(staged.messages, &project_message?/1)}
       end},
      {:tool_projection,
       fn staged ->
         [first | rest] = staged.tools
         changed = Map.update!(first, "description", &same_size_substitution/1)
         %{staged | tools: [changed | rest]}
       end}
    ]

    for {label, mutate} <- request_mutations do
      mutated_request = restage_request(mutate.(request))

      malformed =
        mutate_model_request(record_prefix, fn payload ->
          Map.put(payload, "request", encode_plain_for_record(mutated_request))
        end)

      assert {:error, _reason} = SessionState.recover(session_id, malformed, event_prefix),
             "#{label} self-consistent request substitution replayed with a stale receipt"
    end

    source_substitution =
      mutate_model_request(record_prefix, fn payload ->
        blocks = get_in(payload, ["context_receipt", "blocks"])

        changed_blocks =
          Enum.map(blocks, fn
            %{"provenance_class" => "session", "source_reference" => reference} = block ->
              put_in(block, ["source_reference"], substitute_source_identity(reference))

            block ->
              block
          end)

        payload
        |> put_in(["context_receipt", "blocks"], changed_blocks)
        |> put_in(
          ["context_receipt", "ordered_descriptor_digest"],
          descriptor_digest(changed_blocks)
        )
      end)

    assert {:error, _reason} =
             SessionState.recover(session_id, source_substitution, event_prefix)
  end

  test "a required-context refusal retains only the compact safe projection and calls no provider" do
    fixture = start_fixture(context_token_budget: 1, script: [%{text: "unreachable"}])
    {session_id, attachment} = create_attached_session(fixture)

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "context_admission_refused_v1",
        self()
      )

    assert {:accepted, "context-refusal"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "context-refusal",
               content: "required context cannot fit"
             })

    assert_receive {:record_held_before_linearization, waiter, _store,
                    "context_admission_refused_v1", transaction},
                   5_000

    assert Enum.map(transaction.records, &record_kind/1) == [
             "context_admission_refused_v1",
             "run_terminal_committed"
           ]

    refute Enum.any?(transaction.outbox, &(record_kind(&1) == "run.started"))
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == []
    M1RuntimeTestStore.release(waiter)

    finished = await_event(attachment, "run.finished")
    all_records = records(fixture, session_id)

    [refusal, terminal] =
      Enum.filter(all_records, fn record ->
        kind?(record, "context_admission_refused_v1") or
          kind?(record, "run_terminal_committed")
      end)

    assert Enum.sort(Map.keys(refusal.payload)) ==
             Enum.sort([
               :kind,
               "run_id",
               "turn_id",
               "category",
               "dimension",
               "token_estimator",
               "descriptor_canonicalization_version",
               "project_disposition",
               "system_message_count",
               "session_message_count",
               "steer_message_count",
               "tool_definition_count",
               "provider_estimated_tokens",
               "context_token_budget",
               "record_byte_cost",
               "context_record_byte_ceiling",
               "ordered_descriptor_digest",
               "observed",
               "limit"
             ])

    assert refusal.payload["category"] == "context_budget_exceeded"
    assert refusal.payload["dimension"] == "context_tokens"
    assert refusal.payload["limit"] == 1
    refute Map.has_key?(refusal.payload, "blocks")
    refute Map.has_key?(refusal.payload, "content")

    failure = %{
      "category" => "context_budget_exceeded",
      "retryable" => false,
      "dimension" => "context_tokens",
      "observed" => refusal.payload["observed"],
      "limit" => 1
    }

    assert terminal.payload["failure"] == failure
    assert finished["failure"] == failure
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == []
    refute Enum.any?(events(fixture, session_id), &(record_kind(&1) == "run.started"))
    refute Enum.any?(all_records, &kind?(&1, "model_request_committed"))
  end

  test "context refusal promotion and recovery preserve the predecessor budget into its successor" do
    [tool | _rest] = @reference_tool_definitions

    fixture =
      start_fixture(
        context_token_budget: 700,
        tools: [tool],
        script: [
          %{
            text: String.duplicate("x", 600),
            hold: true,
            tool_calls: [
              %{id: "context-call", name: "read", arguments: %{"path" => "AGENTS.md"}}
            ]
          },
          %{text: "promoted successor", hold: true}
        ]
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "later-context-prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "later-context-prompt",
               content: "first request fits"
             })

    assert_receive {:context_model_holding, first_worker}, 5_000
    assert {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)

    assert {:accepted, "later-context-steer"} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "later-context-steer",
               run_id: run_id,
               content: String.duplicate("steer", 80)
             })

    assert {:accepted, "later-context-follow-up"} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "later-context-follow-up",
               content: "successor stays small"
             })

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "context_admission_refused_v1",
        self()
      )

    send(first_worker, :release)

    assert_receive {:record_held_before_linearization, waiter, _store,
                    "context_admission_refused_v1", transaction},
                   5_000

    assert Enum.map(transaction.records, &record_kind/1) == [
             "context_admission_refused_v1",
             "run_terminal_committed"
           ]

    assert Enum.map(transaction.outbox, &record_kind/1) == [
             "run.finished",
             "steer.resolved",
             "user.message_appended"
           ]

    [refusal, terminal] = transaction.records
    assert refusal["dimension"] == "context_tokens"
    assert terminal["failure"]["dimension"] == "context_tokens"
    assert length(Loopex.ContextAdmissionTestModel.requests(fixture.model)) == 1
    refute Enum.any?(transaction.outbox, &(record_kind(&1) in ["run.started", "session.settled"]))

    M1RuntimeTestStore.release(waiter)
    assert_receive {:context_model_holding, _successor_worker}, 5_000

    ordered =
      fixture
      |> events(session_id)
      |> Enum.filter(
        &(record_kind(&1) in [
            "run.finished",
            "steer.resolved",
            "user.message_appended",
            "run.started"
          ])
      )
      |> Enum.map(&record_kind/1)

    assert Enum.take(ordered, -4) == [
             "run.finished",
             "steer.resolved",
             "user.message_appended",
             "run.started"
           ]

    assert length(Loopex.ContextAdmissionTestModel.requests(fixture.model)) == 2

    refute Enum.any?(records(fixture, session_id), fn record ->
             record_kind(record) in ["follow_up_promoted", "steer_resolved"]
           end)

    assert {:ok, %{active_context_token_budget: 700}} =
             Loopex.session_status(fixture.runtime, session_id)

    :ok = Loopex.stop(fixture.runtime)
    replacement = restart_fixture(fixture)

    assert {:ok, {:prepared, recovered_activation}} =
             dynamic_apply(Loopex, :prepare_resume_session, [
               replacement,
               session_id,
               "recover-promoted-context-budget"
             ])

    assert {:ok, %{active_context_token_budget: 700}} =
             Loopex.session_status(replacement, session_id)

    assert :ok = dynamic_apply(Loopex, :abandon_resume, [recovered_activation])
  end

  test "context refusal replay validates every compact dimension relation and rejects every broken pair" do
    fixture = start_fixture(context_token_budget: 1, script: [%{text: "unreachable"}])
    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "replay-context-refusal"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "replay-context-refusal",
               content: "refuse"
             })

    assert await_event(attachment, "run.finished")["outcome"] == "failed"
    base_records = records(fixture, session_id)
    base_events = events(fixture, session_id)

    assert {:ok, _baseline} = SessionState.recover(session_id, base_records, base_events),
           "the unmutated refusal corpus must replay before a broken pair can prove refusal"

    cases = [
      {"system_class_tokens", 1_000, 1_000, nil, 1_000, 8_192,
       [
         %{"observed" => 999},
         %{"observed" => 1_001},
         %{"limit" => 999},
         %{"record_byte_cost" => 1_000}
       ]},
      {"context_tokens", 2, 1, nil, 2, 1,
       [
         %{"observed" => 3},
         %{"observed" => 1},
         %{"limit" => 2},
         %{"record_byte_cost" => 2}
       ]},
      {"context_record_bytes", @record_limit + 1, @record_limit, @record_limit + 1, 2, 8_192,
       [
         %{"record_byte_cost" => nil},
         %{"record_byte_cost" => @record_limit + 2},
         %{"limit" => @record_limit - 1},
         %{"observed" => @record_limit, "record_byte_cost" => @record_limit}
       ]},
      {"context_record_depth", @max_item_depth + 1, @max_item_depth, nil, 2, 8_192,
       [
         %{"observed" => @max_item_depth + 2},
         %{"limit" => @max_item_depth - 1},
         %{"record_byte_cost" => @max_item_depth + 1}
       ]},
      {"context_record_cardinality", @max_item_cardinality + 1, @max_item_cardinality, nil, 2,
       8_192,
       [
         %{"observed" => @max_item_cardinality + 2},
         %{"limit" => @max_item_cardinality - 1},
         %{"record_byte_cost" => @max_item_cardinality + 1}
       ]}
    ]

    for {dimension, observed, limit, record_byte_cost, provider_estimated_tokens,
         context_token_budget, invalid_relations} <- cases do
      {dimension_records, dimension_events} =
        rewrite_context_failure(
          base_records,
          base_events,
          dimension,
          observed,
          limit,
          record_byte_cost,
          provider_estimated_tokens,
          context_token_budget
        )

      assert {:ok, recovered} =
               SessionState.recover(session_id, dimension_records, dimension_events)

      assert recovered.active_run_id == nil

      for updates <- invalid_relations do
        {malformed_records, malformed_events} =
          mutate_context_relation(dimension_records, dimension_events, updates)

        assert {:error, _reason} =
                 SessionState.recover(session_id, malformed_records, malformed_events),
               "#{dimension} accepted invalid relation #{inspect(updates)}"
      end

      {wrong_budget_records, wrong_budget_events} =
        mutate_context_relation(dimension_records, dimension_events, %{
          "context_token_budget" => context_token_budget + 1
        })

      assert {:error, _reason} =
               SessionState.recover(session_id, wrong_budget_records, wrong_budget_events),
             "#{dimension} accepted the wrong committed context budget"
    end

    refusal_index = Enum.find_index(base_records, &kind?(&1, "context_admission_refused_v1"))
    terminal_index = refusal_index + 1
    refusal = Enum.at(base_records, refusal_index)
    terminal = Enum.at(base_records, terminal_index)

    malformed = [
      {:missing_tail, List.delete_at(base_records, terminal_index), base_events},
      {:duplicate_first, List.insert_at(base_records, terminal_index, refusal), base_events},
      {:reordered_pair,
       base_records
       |> List.replace_at(refusal_index, terminal)
       |> List.replace_at(terminal_index, refusal), base_events},
      {:mismatched_run,
       List.update_at(base_records, terminal_index, fn record ->
         put_in(record, [:payload, "run_id"], "r_other")
       end), base_events},
      {:mismatched_failure,
       List.update_at(base_records, terminal_index, fn record ->
         update_in(record, [:payload, "failure", "observed"], &(&1 + 1))
       end), base_events},
      {:wrong_turn,
       List.update_at(base_records, refusal_index, fn record ->
         put_in(record, [:payload, "turn_id"], "t_wrong")
       end), base_events},
      {:unknown_member,
       List.update_at(base_records, refusal_index, fn record ->
         put_in(record, [:payload, "unexpected"], true)
       end), base_events}
    ]

    for {label, malformed_records, malformed_events} <- malformed do
      assert {:error, _reason} =
               SessionState.recover(session_id, malformed_records, malformed_events),
             "#{label} context pair replayed"
    end
  end

  test "revision two phase and cross version replay fail closed in both directions" do
    fixture =
      start_fixture(
        context_token_budget: 8_192,
        script: [%{text: "finish revision two", hold: true}]
      )

    {session_id, attachment} = create_attached_session(fixture)

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_request_committed",
        self()
      )

    assert {:accepted, "revision-two-phase"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "revision-two-phase",
               content: "retain every phase"
             })

    assert_receive {:record_held_before_linearization, staging_waiter, _store,
                    "model_request_committed", _transaction},
                   5_000

    admitted_events = events(fixture, session_id)
    admitted_anchor = List.last(admitted_events).event_sequence

    assert {:ok, admitted_snapshot} =
             SessionState.snapshot(session_id, admitted_anchor, admitted_events)

    assert_revision_two_snapshot(
      admitted_snapshot,
      session_id,
      admitted_anchor,
      "admitted_unstaged"
    )

    M1RuntimeTestStore.release(staging_waiter)

    assert await_event(attachment, "run.started")["run_id"] ==
             Map.fetch!(admitted_snapshot, :active_run_id)

    assert_receive {:context_model_holding, model_worker}, 5_000

    started_events = events(fixture, session_id)
    started_anchor = List.last(started_events).event_sequence

    assert {:ok, started_snapshot} =
             SessionState.snapshot(session_id, started_anchor, started_events)

    assert_revision_two_snapshot(started_snapshot, session_id, started_anchor, "started")

    assert Map.fetch!(started_snapshot, :active_run_id) ==
             Map.fetch!(admitted_snapshot, :active_run_id)

    send(model_worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    complete_events = events(fixture, session_id)
    complete_anchor = List.last(complete_events).event_sequence

    assert {:ok, finished_snapshot} =
             SessionState.snapshot(session_id, complete_anchor, complete_events)

    assert Enum.sort(Map.keys(finished_snapshot)) ==
             Enum.sort([
               :snapshot_revision,
               :session_id,
               :event_sequence,
               :active_run_id,
               :active_run_phase
             ])

    assert dynamic_apply(Map, :get, [finished_snapshot, :snapshot_revision]) == 2
    assert dynamic_apply(Map, :get, [finished_snapshot, :session_id]) == session_id
    assert dynamic_apply(Map, :get, [finished_snapshot, :event_sequence]) == complete_anchor
    assert dynamic_apply(Map, :get, [finished_snapshot, :active_run_id]) == nil
    assert dynamic_apply(Map, :get, [finished_snapshot, :active_run_phase]) == nil

    assert {:ok, historical_admitted} =
             SessionState.snapshot(session_id, admitted_anchor, complete_events)

    assert {:ok, historical_started} =
             SessionState.snapshot(session_id, started_anchor, complete_events)

    assert historical_admitted == admitted_snapshot
    assert historical_started == started_snapshot

    legacy_records =
      Enum.map(records(fixture, session_id), fn record ->
        if kind?(record, "prompt_admitted_v2") do
          legacy_payload =
            record.payload
            |> Map.delete("context_token_budget")
            |> Map.put(:kind, "command_admitted")

          %{record | payload: legacy_payload}
        else
          record
        end
      end)

    assert Enum.any?(legacy_records, &kind?(&1, "command_admitted"))
    assert {:error, _reason} = SessionState.recover(session_id, legacy_records, complete_events)

    # The opposite-direction assertion requires the bound pre-R reducer binary;
    # this current-tree selector deliberately does not counterfeit that runtime.
  end

  test "page-size-one replay survives a crash after the refusal row and applies its terminal once" do
    fixture =
      start_fixture(
        context_token_budget: 1,
        script: [%{text: "must never dispatch"}],
        page_size_one: true
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, "page-one-refusal"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "page-one-refusal",
               content: "refuse before provider"
             })

    assert await_event(attachment, "run.finished")["outcome"] == "failed"

    [refusal] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "context_admission_refused_v1"))

    Agent.update(fixture.page_control, fn _old -> refusal.journal_version end)
    :ok = Loopex.stop(fixture.runtime)
    parent = self()

    first_runtime = restart_fixture(fixture)

    {first_caller, first_monitor} =
      spawn_monitor(fn ->
        send(parent, {
          :first_page_resume_result,
          Loopex.resume_session(first_runtime, session_id, command_id: "page-one-first")
        })
      end)

    assert_receive {:context_page_boundary_held, blocked_owner, _token, ^session_id,
                    refusal_version},
                   5_000

    assert refusal_version == refusal.journal_version
    assert blocked_owner == coordinator_of(first_runtime)
    owner_monitor = Process.monitor(blocked_owner)
    Process.exit(blocked_owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^blocked_owner, :killed}, 5_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first_caller, _reason}, 5_000
    stop_runtime(first_runtime)

    second_runtime = restart_fixture(fixture)

    {second_caller, second_monitor} =
      spawn_monitor(fn ->
        send(parent, {
          :second_page_resume_result,
          Loopex.resume_session(second_runtime, session_id, command_id: "page-one-second")
        })
      end)

    assert_receive {:context_page_boundary_held, second_owner, token, ^session_id,
                    ^refusal_version},
                   5_000

    send(second_owner, {:release_context_page, token})
    assert_receive {:second_page_resume_result, {:ok, ^session_id}}, 5_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second_caller, :normal}, 5_000

    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == []

    assert Enum.count(records(fixture, session_id), &kind?(&1, "context_admission_refused_v1")) ==
             1

    assert Enum.count(records(fixture, session_id), &kind?(&1, "run_terminal_committed")) == 1
  end

  test "a prepared resume exposes retained context so omission recovers it and a mismatch can abandon before activation" do
    fixture =
      start_fixture(
        context_token_budget: 321,
        script: [%{text: "held", hold: true}, %{text: "must not be redispatched"}]
      )

    {session_id, attachment} = create_attached_session(fixture)

    :ok = M1RuntimeTestStore.delay_after_record(fixture.store, "prompt_admitted_v2", self())

    prepared_prompt =
      Task.async(fn ->
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "prepared-context",
          content: "hold"
        })
      end)

    # ADR 0018: an attempt inherited open and dispatched settles as owner loss,
    # so the first owner dies at the durable prompt admission, before any attempt
    # opens; the activated successor is the one that opens and holds.
    assert_receive {:record_linearized, admission_waiter, _store, "prompt_admitted_v2",
                    _transition, {:committed, _tx_id, _receipt}},
                   5_000

    coordinator = coordinator_of(fixture.runtime)
    reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^reference, :process, ^coordinator, :killed}, 5_000
    M1RuntimeTestStore.release(admission_waiter)
    _ = Task.yield(prepared_prompt, 5_000) || Task.shutdown(prepared_prompt, :brutal_kill)

    assert {:ok, {:prepared, activation}} =
             dynamic_apply(Loopex, :prepare_resume_session, [
               fixture.runtime,
               session_id,
               "resume-omitted-context"
             ])

    assert {:ok, %{active_context_token_budget: 321}} =
             Loopex.session_status(fixture.runtime, session_id)

    assert {:ok, ^session_id} = dynamic_apply(Loopex, :activate_resume, [activation])
    assert_receive {:context_model_holding, _model_worker}, 5_000

    successor = coordinator_of(fixture.runtime)
    successor_reference = Process.monitor(successor)
    Process.exit(successor, :kill)
    assert_receive {:DOWN, ^successor_reference, :process, ^successor, :killed}, 5_000

    assert {:ok, {:prepared, mismatched}} =
             dynamic_apply(Loopex, :prepare_resume_session, [
               fixture.runtime,
               session_id,
               "resume-explicit-mismatch"
             ])

    assert {:ok, %{active_context_token_budget: retained}} =
             Loopex.session_status(fixture.runtime, session_id)

    explicit_context_token_budget = 8_192

    refute retained == explicit_context_token_budget
    assert retained == 321
    requests_before_abandon = Loopex.ContextAdmissionTestModel.requests(fixture.model)

    # The reference host compares the explicit value with this retained value
    # before activating the prepared owner. A mismatch spends the capability by
    # abandoning it; it may not activate first and clean up afterwards.
    assert :ok = dynamic_apply(Loopex, :abandon_resume, [mismatched])

    assert {:error, _already_abandoned} = dynamic_apply(Loopex, :activate_resume, [mismatched])
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == requests_before_abandon
  end

  test "project resolution locks zero or one shapes first failure order and bounded inspection" do
    rejected_size = @record_limit + 1

    assert {:declined, :no_manifest, %{}} = ProjectResource.resolve(nil, nil)

    empty_manifest = %{entries: [], workspace: project_workspace()}
    {:ok, empty_digest, []} = ProjectResource.digest(empty_manifest)

    assert {:staged, [],
            %{
              "manifest_digest" => ^empty_digest,
              "decision_source" => "host_supplied",
              "workspace_ref" => "workspace-ref",
              "entries" => []
            }} = ProjectResource.resolve(empty_manifest, project_decision(empty_digest))

    invalid_outer = %{
      entries: [project_entry("must not be inspected")],
      workspace: project_workspace(),
      unexpected: :member
    }

    assert {:declined, :manifest_rejected, %{"reason" => "invalid_manifest", "label" => nil}} =
             ProjectResource.resolve(invalid_outer, nil)

    improper_entries = %{
      entries: [project_entry("first") | :unvisited_tail],
      workspace: project_workspace()
    }

    assert {:declined, :manifest_rejected, %{"reason" => "invalid_manifest", "label" => nil}} =
             ProjectResource.resolve(improper_entries, nil)

    two_entries = %{
      entries: [project_entry("first"), %{not: "an entry"}],
      workspace: project_workspace()
    }

    assert {:declined, :manifest_rejected, %{"reason" => "too_many_entries", "label" => nil}} =
             ProjectResource.resolve(two_entries, nil)

    two_entries_with_unvisited_tail = %{
      entries: [project_entry("first"), %{must_not: "be inspected"} | :unvisited_tail],
      workspace: project_workspace()
    }

    assert {:declined, :manifest_rejected, %{"reason" => "too_many_entries", "label" => nil}} =
             ProjectResource.resolve(two_entries_with_unvisited_tail, nil)

    invalid_workspace = %{
      entries: [project_entry("entry must not choose the answer")],
      workspace: Map.put(project_workspace(), :unexpected, "member")
    }

    assert {:declined, :manifest_rejected, %{"reason" => "invalid_workspace", "label" => nil}} =
             ProjectResource.resolve(invalid_workspace, nil)

    invalid_entry = %{
      entries: [Map.put(project_entry("entry"), :unexpected, "member")],
      workspace: project_workspace()
    }

    assert {:declined, :manifest_rejected,
            %{"reason" => "entry_not_bounded_plain_data", "label" => nil}} =
             ProjectResource.resolve(invalid_entry, nil)

    unpermitted =
      project_entry("abc", String.duplicate("0", 64))
      |> Map.merge(%{label: "README.md", contained: false, byte_size: 99})

    assert {:declined, :manifest_rejected,
            %{"reason" => "unpermitted_label", "label" => "README.md"}} =
             ProjectResource.resolve(
               %{entries: [unpermitted], workspace: project_workspace()},
               nil
             )

    uncontained =
      project_entry("abc", String.duplicate("0", 64))
      |> Map.merge(%{contained: false, byte_size: 99})

    assert {:declined, :manifest_rejected,
            %{"reason" => "entry_not_reported_contained", "label" => "AGENTS.md"}} =
             ProjectResource.resolve(
               %{entries: [uncontained], workspace: project_workspace()},
               nil
             )

    wrong_size = project_entry("abc", String.duplicate("0", 64)) |> Map.put(:byte_size, 99)

    assert {:declined, :manifest_rejected,
            %{"reason" => "declared_size_mismatch", "label" => "AGENTS.md"}} =
             ProjectResource.resolve(
               %{entries: [wrong_size], workspace: project_workspace()},
               nil
             )

    oversized = String.duplicate("x", @record_limit + 1)

    oversized_manifest = %{
      entries: [project_entry(oversized, String.duplicate("0", 64))],
      workspace: project_workspace()
    }

    trace_hash_calls(true)

    try do
      # Concept: the refutation below is only evidence if the tracer would have
      # spoken, and it is only evidence about hashing if it watches the process
      # that hashes.
      #
      # Technical depth: a body small enough to reach the digest comparison is
      # hashed, so this is a positive control on the exact call the refutation
      # names -- same module, same function, same arity, same traced process. A
      # trace pattern that matched nothing, or an implementation that hashed
      # through some other entry, makes this fail rather than making the
      # refutation vacuously true.
      assert {control_result, control_hashes} =
               hash_calls(fn ->
                 ProjectResource.resolve(
                   %{
                     entries: [project_entry("abc", String.duplicate("0", 64))],
                     workspace: project_workspace()
                   },
                   nil
                 )
               end)

      assert {:declined, :manifest_rejected,
              %{"reason" => "declared_digest_mismatch", "label" => "AGENTS.md"}} =
               control_result

      assert control_hashes > 0,
             "no hash was observed on a path that must hash, so the refutation below is vacuous"

      assert {oversized_result, oversized_hashes} =
               hash_calls(fn -> ProjectResource.resolve(oversized_manifest, nil) end)

      assert {:declined, :over_limit,
              %{
                "dimension" => "project_resource_bytes",
                "observed" => ^rejected_size,
                "limit" => @record_limit,
                "label" => "AGENTS.md"
              }} = oversized_result

      assert oversized_hashes == 0,
             "an oversized body was hashed before its O(1) byte refusal"
    after
      trace_hash_calls(false)
    end

    wrong_digest = project_entry("abc", String.duplicate("0", 64))

    assert {:declined, :manifest_rejected,
            %{"reason" => "declared_digest_mismatch", "label" => "AGENTS.md"}} =
             ProjectResource.resolve(
               %{entries: [wrong_digest], workspace: project_workspace()},
               nil
             )

    valid = %{entries: [project_entry("valid")], workspace: project_workspace()}
    {:ok, manifest_digest, _ordered} = ProjectResource.digest(valid)

    assert {:declined, :no_decision, %{"manifest_digest" => ^manifest_digest}} =
             ProjectResource.resolve(valid, nil)

    for revocation <- ["revoked", "pending", "", :active, nil] do
      invalid_decision = project_decision(manifest_digest, revocation_state: revocation)

      assert {:declined, :binding_changed,
              %{
                "reason" => "invalid_decision",
                "expected_manifest_digest" => ^manifest_digest,
                "decision_manifest_digest" => ^manifest_digest
              }} = ProjectResource.resolve(valid, invalid_decision)
    end

    for expiry <- [
          "2099-01-01T00:00:00Z",
          "2020-01-01T00:00:00Z",
          "not-an-instant",
          0
        ] do
      invalid_decision = project_decision(manifest_digest, expires_at: expiry)

      assert {:declined, :binding_changed,
              %{
                "reason" => "invalid_decision",
                "expected_manifest_digest" => ^manifest_digest,
                "decision_manifest_digest" => ^manifest_digest
              }} = ProjectResource.resolve(valid, invalid_decision)
    end

    different_digest =
      if String.duplicate("f", 64) == manifest_digest,
        do: String.duplicate("e", 64),
        else: String.duplicate("f", 64)

    assert {:declined, :binding_changed,
            %{
              "reason" => "digest_mismatch",
              "expected_manifest_digest" => ^manifest_digest,
              "decision_manifest_digest" => ^different_digest
            }} =
             ProjectResource.resolve(
               valid,
               project_decision(different_digest, workspace_ref: "other-workspace")
             )

    assert {:declined, :binding_changed,
            %{
              "reason" => "workspace_mismatch",
              "expected_manifest_digest" => ^manifest_digest,
              "decision_manifest_digest" => ^manifest_digest
            }} =
             ProjectResource.resolve(
               valid,
               project_decision(manifest_digest, workspace_ref: "other-workspace")
             )

    assert {:staged, [_block], %{"manifest_digest" => ^manifest_digest}} =
             ProjectResource.resolve(valid, project_decision(manifest_digest))

    huge_outer = enormous_map(%{entries: [], workspace: %{must_not: "be inspected"}})

    assert {:declined, :manifest_rejected, %{"reason" => "invalid_manifest", "label" => nil}} =
             ProjectResource.resolve(huge_outer, nil)

    huge_workspace = %{
      entries: [],
      workspace: enormous_map(project_workspace())
    }

    assert {:declined, :manifest_rejected, %{"reason" => "invalid_workspace", "label" => nil}} =
             ProjectResource.resolve(huge_workspace, nil)

    huge_entry = %{
      entries: [enormous_map(project_entry("must not be inspected"))],
      workspace: project_workspace()
    }

    assert {:declined, :manifest_rejected,
            %{"reason" => "entry_not_bounded_plain_data", "label" => nil}} =
             ProjectResource.resolve(huge_entry, nil)

    huge_decision = enormous_map(project_decision(manifest_digest))

    assert {:declined, :binding_changed,
            %{
              "reason" => "invalid_decision",
              "expected_manifest_digest" => ^manifest_digest,
              "decision_manifest_digest" => ^manifest_digest
            }} = ProjectResource.resolve(valid, huge_decision)
  end

  defp start_fixture(options) do
    script = Keyword.fetch!(options, :script)
    context_token_budget = Keyword.fetch!(options, :context_token_budget)
    {:ok, model} = Loopex.ContextAdmissionTestModel.start(script, self())
    {store_pid, base_store} = M1RuntimeTestStore.start_store(label: "context-admission")
    page_size_one = Keyword.get(options, :page_size_one, false)

    {store, page_control} =
      if page_size_one do
        {:ok, control} = Agent.start_link(fn -> nil end)

        {:ok, wrapped} =
          Store.new(Loopex.ContextAdmissionPageOneStore, %{
            store: store_pid,
            page_control: control,
            observer: self()
          })

        {wrapped, control}
      else
        {base_store, nil}
      end

    tools = Keyword.get(options, :tools, [])

    runtime_options =
      [
        runtime_id: "context-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: Loopex.ContextAdmissionTestModel,
          model: "fixture:v1",
          options: [state: model]
        },
        executor: %{
          module: Loopex.ContextAdmissionTestExecutor,
          reference: self(),
          identity: "context-test-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        policy: Loopex.ContextAdmissionTestPolicy,
        bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: 60_000},
        project_manifest: Keyword.get(options, :project_manifest),
        project_decision: Keyword.get(options, :project_decision),
        tools: tools,
        active_tools: Enum.map(tools, &Map.fetch!(&1, "tool_id"))
      ]

    runtime = start_runtime_compat(runtime_options, context_token_budget)

    fixture = %{
      runtime: runtime,
      runtime_options: runtime_options,
      context_token_budget: context_token_budget,
      model: model,
      store: store_pid,
      store_handle: store,
      page_control: page_control
    }

    on_exit(fn ->
      stop_runtime(fixture.runtime)
      stop_process(store_pid)
      stop_process(model)
      if is_pid(page_control), do: stop_process(page_control)
    end)

    fixture
  end

  defp restart_fixture(fixture) do
    replacement = start_runtime_compat(fixture.runtime_options, fixture.context_token_budget)
    on_exit(fn -> stop_runtime(replacement) end)
    replacement
  end

  # The compatibility fallback lets every later lock reach the pre-ADR behavior
  # it names. The dedicated validation case above is what makes deleting the new
  # required option impossible once the implementation exists.
  defp start_runtime_compat(options, context_token_budget) do
    with_context = Keyword.put(options, :context_token_budget, context_token_budget)

    case Loopex.start_link(with_context) do
      {:ok, runtime} -> runtime
      {:error, :invalid_runtime_options} -> options |> Loopex.start_link() |> elem(1)
    end
  end

  defp create_attached_session(fixture) do
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"tenant" => "context"},
        command_id: "create-#{System.unique_integer([:positive])}"
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    {session_id, attachment}
  end

  defp records(fixture, session_id) do
    M1RuntimeTestStore.inspect_state(fixture.store).sessions[session_id].records
  end

  defp events(fixture, session_id) do
    M1RuntimeTestStore.inspect_state(fixture.store).sessions[session_id].events
  end

  defp kind?(record, kind), do: record.payload[:kind] == kind

  defp record_kind(%{payload: payload}), do: record_kind(payload)
  defp record_kind(item) when is_map(item), do: Map.get(item, :kind) || Map.get(item, "kind")

  defp assert_revision_two_snapshot(snapshot, session_id, event_sequence, phase) do
    assert Enum.sort(Map.keys(snapshot)) ==
             Enum.sort([
               :snapshot_revision,
               :session_id,
               :event_sequence,
               :active_run_id,
               :active_run_phase
             ])

    assert Map.get(snapshot, :snapshot_revision) == 2
    assert Map.get(snapshot, :session_id) == session_id
    assert Map.get(snapshot, :event_sequence) == event_sequence
    assert is_binary(Map.get(snapshot, :active_run_id))
    assert Map.get(snapshot, :active_run_id) != ""
    assert Map.get(snapshot, :active_run_phase) == phase
  end

  defp command_refusal_keys do
    Enum.sort([
      :kind,
      "command_id",
      "command_digest",
      "command_type",
      "admission",
      "dimension",
      "candidate",
      "observed",
      "limit"
    ])
  end

  defp required_context_candidate(blocks) do
    %{
      :kind => "model_request_committed",
      "run_id" => "r_required_context",
      "turn_id" => "t_required_context",
      "request" => %{
        "model" => "fixture:v1",
        "messages" => [],
        "tools" => [],
        "sampling" => %{"max_tokens" => 1},
        "deadline" => 1
      },
      "context_receipt" => %{
        "provider_identity" => "loopex.context.reference",
        "provider_revision" => 2,
        "transformer_identity" => nil,
        "transformer_revision" => nil,
        "selector_identity" => nil,
        "selector_revision" => nil,
        "token_estimator" => "loopex.context_bytes.v1",
        "descriptor_canonicalization_version" => "loopex.canonical.v1",
        "blocks" => blocks,
        "totals" => %{
          "byte_cost" => 0,
          "token_cost" => 0,
          "by_provenance" => %{
            "system" => %{"byte_cost" => 0, "token_cost" => 0},
            "session" => %{"byte_cost" => 0, "token_cost" => 0},
            "project_resource" => %{"byte_cost" => 0, "token_cost" => 0}
          }
        },
        "project_resource" => %{
          "class" => "project_resource",
          "receipt_revision" => 2,
          "disposition" => "no_manifest",
          "detail" => %{}
        },
        "context_token_budget" => 8_192,
        "provider_estimated_tokens" => 0,
        "context_record_byte_ceiling" => @record_limit,
        "record_byte_cost" => 0,
        "ordered_descriptor_digest" => String.duplicate("0", 64)
      }
    }
  end

  defp sized_context_candidate(target), do: sized_context_candidate(target, 0, target, nil)

  defp sized_context_candidate(_target, low, high, found) when low > high do
    found || flunk("no required-context candidate has the requested normalized size")
  end

  defp sized_context_candidate(target, low, high, found) do
    body_size = div(low + high, 2)

    candidate =
      required_context_candidate([
        %{
          "source_reference" => %{"kind" => "system", "identity" => "loopex.system.v1"},
          "provenance_class" => "system",
          "trust_class" => "host_owned_trusted_brain_content",
          "content_digest" => String.duplicate("0", 64),
          "byte_cost" => body_size,
          "token_cost" => 0
        }
      ])
      |> put_in(
        ["request", "messages"],
        [%{"role" => "user", "content" => String.duplicate("x", body_size)}]
      )

    case independent_record_size(candidate) do
      ^target ->
        candidate

      bytes when bytes < target ->
        sized_context_candidate(target, body_size + 1, high, found)

      _bytes ->
        sized_context_candidate(target, low, body_size - 1, found)
    end
  end

  # Maintainer override, 2026-09-01: measure the record as committed, with its
  # restored atom `:kind`, exactly as ADR 0017 defines `encoded_bytes`.
  defp independent_record_size(%{kind: _kind} = record) do
    record
    |> :erlang.term_to_binary([:deterministic])
    |> byte_size()
  end

  defp nested_value(0), do: "leaf"
  defp nested_value(depth), do: %{"next" => nested_value(depth - 1)}

  defp traced_transactions(store, acc \\ []) do
    receive do
      {:trace, ^store, :receive, {:"$gen_call", _from, {:transact, transaction}}} ->
        traced_transactions(store, [transaction | acc])

      _other ->
        traced_transactions(store, acc)
    after
      50 ->
        :erlang.trace(store, false, [:all])
        Enum.reverse(acc)
    end
  end

  defp rewrite_context_failure(
         records,
         events,
         dimension,
         observed,
         limit,
         record_byte_cost,
         provider_estimated_tokens,
         context_token_budget
       ) do
    failure = %{
      "category" => "context_budget_exceeded",
      "retryable" => false,
      "dimension" => dimension,
      "observed" => observed,
      "limit" => limit
    }

    records =
      Enum.map(records, fn record ->
        case record_kind(record) do
          "context_admission_refused_v1" ->
            payload =
              record.payload
              |> Map.put("dimension", dimension)
              |> Map.put("observed", observed)
              |> Map.put("limit", limit)
              |> Map.put("record_byte_cost", record_byte_cost)
              |> Map.put("provider_estimated_tokens", provider_estimated_tokens)
              |> Map.put("context_token_budget", context_token_budget)

            %{record | payload: payload}

          "prompt_admitted_v2" ->
            %{
              record
              | payload: Map.put(record.payload, "context_token_budget", context_token_budget)
            }

          "run_terminal_committed" ->
            %{record | payload: Map.put(record.payload, "failure", failure)}

          _other ->
            record
        end
      end)

    events =
      Enum.map(events, fn event ->
        if record_kind(event) == "run.finished" do
          Map.put(event, "failure", failure)
        else
          event
        end
      end)

    {records, events}
  end

  defp mutate_context_relation(records, events, updates) do
    records =
      Enum.map(records, fn record ->
        if kind?(record, "context_admission_refused_v1") do
          %{record | payload: Map.merge(record.payload, updates)}
        else
          record
        end
      end)

    refusal = Enum.find(records, &kind?(&1, "context_admission_refused_v1"))

    failure = %{
      "category" => refusal.payload["category"],
      "retryable" => false,
      "dimension" => refusal.payload["dimension"],
      "observed" => refusal.payload["observed"],
      "limit" => refusal.payload["limit"]
    }

    records =
      Enum.map(records, fn record ->
        if kind?(record, "run_terminal_committed") do
          %{record | payload: Map.put(record.payload, "failure", failure)}
        else
          record
        end
      end)

    events =
      Enum.map(events, fn event ->
        if record_kind(event) == "run.finished" do
          Map.put(event, "failure", failure)
        else
          event
        end
      end)

    {records, events}
  end

  defp mutate_model_request(records, mutate) do
    Enum.map(records, fn record ->
      if kind?(record, "model_request_committed") do
        %{record | payload: mutate.(record.payload)}
      else
        record
      end
    end)
  end

  defp records_through_kind(records, kind) do
    case Enum.find_index(records, &kind?(&1, kind)) do
      nil -> flunk("fixture never committed #{kind}")
      index -> Enum.take(records, index + 1)
    end
  end

  defp recoverable_event_prefix(session_id, records, events) do
    Enum.find_value(0..length(events), fn count ->
      prefix = Enum.take(events, count)

      case SessionState.recover(session_id, records, prefix) do
        {:ok, _state} -> prefix
        {:error, _reason} -> nil
      end
    end) || flunk("no public-event prefix matches the staged-request record prefix")
  end

  defp restage_request(request) do
    assert {:ok, restaged} =
             Model.request(request.model, request.messages,
               tools: request.tools,
               sampling: request.sampling,
               deadline: request.deadline
             )

    restaged
  end

  defp replace_message(messages, predicate) do
    {replaced, count} =
      Enum.map_reduce(messages, 0, fn message, count ->
        if predicate.(message) do
          {Map.update!(message, "content", &same_size_substitution/1), count + 1}
        else
          {message, count}
        end
      end)

    assert count == 1
    replaced
  end

  defp project_message?(%{"role" => "user", "content" => content}) when is_binary(content),
    do: String.starts_with?(content, "<project_resource label=\"")

  defp project_message?(_message), do: false

  defp same_size_substitution(<<first, rest::binary>>) do
    replacement = if first == ?x, do: ?y, else: ?x
    <<replacement, rest::binary>>
  end

  defp substitute_source_identity(reference) when is_binary(reference),
    do: same_size_substitution(reference)

  defp substitute_source_identity(reference) when is_map(reference) do
    key =
      Enum.find(~w(command_id identity relative_label tool_id workspace_ref), fn candidate ->
        is_binary(Map.get(reference, candidate)) and Map.get(reference, candidate) != ""
      end)

    if key do
      Map.update!(reference, key, &same_size_substitution/1)
    else
      flunk("structured source reference has no substitutable identity member")
    end
  end

  defp encode_plain_for_record(value) when value in [nil, true, false], do: value
  defp encode_plain_for_record(value) when is_atom(value), do: Atom.to_string(value)

  defp encode_plain_for_record(value)
       when is_binary(value) or is_integer(value) or is_float(value),
       do: value

  defp encode_plain_for_record(value) when is_list(value),
    do: Enum.map(value, &encode_plain_for_record/1)

  defp encode_plain_for_record(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      encoded_key = if is_atom(key), do: Atom.to_string(key), else: key
      {encoded_key, encode_plain_for_record(nested)}
    end)
  end

  defp descriptor_digest(blocks) do
    context =
      :crypto.hash_init(:sha256)
      |> :crypto.hash_update("loopex.context.descriptors.v1" <> <<0>>)

    context =
      Enum.reduce(blocks, context, fn block, hash ->
        bytes = Canonical.encode(block)

        hash
        |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
        |> :crypto.hash_update(bytes)
      end)

    context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp source_reference_goldens do
    [
      {
        %{"kind" => "system", "identity" => "loopex.system.v1"},
        "836802770a6c6f6f7065785f6d61706c0000000268026d000000046b696e646d0000000673797374656d68026d000000086964656e746974796d000000106c6f6f7065782e73797374656d2e76316a",
        "b6e6abe0e0f9b949ee1b80df797c06fb88137821ce4f743d56957dfcba0dd64f"
      },
      {
        %{
          "kind" => "session_command",
          "run_id" => "r:a|b",
          "command_id" => "c:b|a"
        },
        "836802770a6c6f6f7065785f6d61706c0000000368026d000000046b696e646d0000000f73657373696f6e5f636f6d6d616e6468026d0000000672756e5f69646d00000005723a617c6268026d0000000a636f6d6d616e645f69646d00000005633a627c616a",
        "7d543496cfad446e0cdec0c4572a9d419404ec303416b2d7ae622c6f823ee995"
      },
      {
        %{"kind" => "session_assistant", "run_id" => "r:a|b", "turn" => 1},
        "836802770a6c6f6f7065785f6d61706c0000000368026d000000046b696e646d0000001173657373696f6e5f617373697374616e7468026d000000047475726e610168026d0000000672756e5f69646d00000005723a617c626a",
        "5c08649267f685a9087a15cdddbc1f24efc970c774588dad8f7cc4d5e7d86652"
      },
      {
        %{
          "kind" => "session_tool_result",
          "run_id" => "r:a|b",
          "turn" => 1,
          "call_id" => "call:|"
        },
        "836802770a6c6f6f7065785f6d61706c0000000468026d000000046b696e646d0000001373657373696f6e5f746f6f6c5f726573756c7468026d000000047475726e610168026d0000000672756e5f69646d00000005723a617c6268026d0000000763616c6c5f69646d0000000663616c6c3a7c6a",
        "69652deffe8b6ba463cf0feab040c38dbfdab3449c1458771bd9a1cd32765704"
      },
      {
        %{"kind" => "session_steer", "run_id" => "r:a|b", "command_id" => "steer:|"},
        "836802770a6c6f6f7065785f6d61706c0000000368026d000000046b696e646d0000000d73657373696f6e5f737465657268026d0000000672756e5f69646d00000005723a617c6268026d0000000a636f6d6d616e645f69646d0000000773746565723a7c6a",
        "db9d639402cd8d8b9e1001164aa6b91b0bde1800a378fc12bf3ffc22165ae990"
      },
      {
        %{
          "kind" => "project_resource",
          "workspace_ref" => "workspace:|",
          "manifest_digest" => String.duplicate("a", 64),
          "relative_label" => "AGENTS.md"
        },
        "836802770a6c6f6f7065785f6d61706c0000000468026d000000046b696e646d0000001070726f6a6563745f7265736f7572636568026d0000000d776f726b73706163655f7265666d0000000b776f726b73706163653a7c68026d0000000e72656c61746976655f6c6162656c6d000000094147454e54532e6d6468026d0000000f6d616e69666573745f6469676573746d00000040616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616a",
        "b5b8497b55b46b513f5656092433a8ecc13816c9516feac0a96a0568e53f037b"
      },
      {
        %{
          "kind" => "tool_definition",
          "tool_id" => "fixture.read",
          "tool_version" => "1.0.0",
          "definition_digest" => String.duplicate("b", 64)
        },
        "836802770a6c6f6f7065785f6d61706c0000000468026d000000046b696e646d0000000f746f6f6c5f646566696e6974696f6e68026d00000007746f6f6c5f69646d0000000c666978747572652e7265616468026d0000000c746f6f6c5f76657273696f6e6d00000005312e302e3068026d00000011646566696e6974696f6e5f6469676573746d00000040626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626a",
        "05378909da31b7aadf9c447373e42ddb246fa51a6e6a872691a28d2fd5edda1c"
      }
    ]
  end

  defp await_event(attachment, kind, attempts \\ 400)

  defp await_event(_attachment, kind, 0), do: flunk("never observed #{kind}")

  defp await_event(attachment, kind, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      {:ok, _other} ->
        await_event(attachment, kind, attempts - 1)

      {:error, :empty} ->
        Process.sleep(5)
        await_event(attachment, kind, attempts - 1)

      _other ->
        Process.sleep(5)
        await_event(attachment, kind, attempts - 1)
    end
  end

  defp coordinator_of(runtime) do
    {:ok, %{sessions: sessions}} = Runtime.children(runtime)

    sessions
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp project_workspace do
    %{workspace_ref: "workspace-ref", repository_origin: nil, revision: nil}
  end

  defp project_entry(content, digest \\ nil) do
    %{
      label: "AGENTS.md",
      content: content,
      byte_size: byte_size(content),
      content_digest: digest || Canonical.digest_bytes(content),
      contained: true
    }
  end

  defp project_decision(manifest_digest, overrides \\ []) do
    %{
      manifest_digest: manifest_digest,
      workspace_ref: "workspace-ref",
      trust_scope: "project_resource",
      decision_source: "host_supplied",
      issued_at: "2026-09-01T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }
    |> Map.merge(Map.new(overrides))
  end

  # Technical depth: staging is driven to its committed request, then the
  # journal is replayed up to but not including that record. The recovered state
  # is therefore the exact boundary the constructor is called from, and the
  # captured request and retained receipt are the exact live preimage rather
  # than a hand-built imitation of one.
  defp staged_candidate(label, options) do
    fixture =
      start_fixture([context_token_budget: @uint64_max, script: [%{text: "done"}]] ++ options)

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, ^label} =
             Loopex.command(attachment, %{type: :prompt, command_id: label, content: label})

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    all_records = records(fixture, session_id)
    staged = records_through_kind(all_records, "model_request_committed")
    prefix = Enum.take(staged, length(staged) - 1)
    event_prefix = recoverable_event_prefix(session_id, prefix, events(fixture, session_id))

    assert {:ok, state} = SessionState.recover(session_id, prefix, event_prefix)

    committed = List.last(staged)

    %{
      state: state,
      run_id: committed.payload["run_id"],
      request: request,
      receipt: committed.payload["context_receipt"]
    }
  end

  defp system_class_refusal(label, tools, options) do
    fixture =
      start_fixture(
        [
          context_token_budget: @uint64_max,
          script: [%{text: "must not dispatch"}],
          tools: tools
        ] ++ options
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, ^label} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: label,
               content: "one required system class over its ceiling"
             })

    finished = await_event(attachment, "run.finished")
    assert Loopex.ContextAdmissionTestModel.requests(fixture.model) == []

    [refusal] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "context_admission_refused_v1"))

    %{failure: finished["failure"], refusal: refusal.payload}
  end

  # Technical depth: tool projections are `system` provenance, so one more
  # bounded definition is what pushes the required system subtotal to its strict
  # 1,000-token ceiling without touching session or project content.
  defp padded_tool_definition do
    @reference_tool_definitions
    |> hd()
    |> Map.merge(%{
      "tool_id" => "loopex.padded",
      "name" => "padded",
      "description" => String.duplicate("bounded description text. ", 40)
    })
  end

  defp run_project_stage(label, manifest, context_token_budget) do
    {:ok, manifest_digest, _entries} = ProjectResource.digest(manifest)

    fixture =
      start_fixture(
        context_token_budget: context_token_budget,
        script: [%{text: "done"}],
        project_manifest: manifest,
        project_decision: project_decision(manifest_digest)
      )

    {session_id, attachment} = create_attached_session(fixture)

    assert {:accepted, ^label} =
             Loopex.command(attachment, %{type: :prompt, command_id: label, content: label})

    assert_receive {:context_model_invoked, _worker, request}, 5_000
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    [committed] =
      fixture
      |> records(session_id)
      |> Enum.filter(&kind?(&1, "model_request_committed"))

    receipt = committed.payload["context_receipt"]

    %{
      manifest_digest: manifest_digest,
      request: request,
      committed: committed.payload,
      receipt: receipt,
      project: receipt["project_resource"]
    }
  end

  defp project_messages(request) do
    Enum.filter(request.messages, fn message ->
      message["role"] == "user" and
        String.starts_with?(message["content"], "<project_resource label=\"")
    end)
  end

  defp project_bucket(receipt),
    do: get_in(receipt, ["totals", "by_provenance", "project_resource"])

  defp resolve_record_cost(record) do
    record
    |> put_in(["context_receipt", "record_byte_cost"], 0)
    |> do_resolve_record_cost(MapSet.new())
  end

  defp do_resolve_record_cost(record, seen) do
    assert {:ok, normalized, measured} =
             dynamic_apply(Store, :normalize_and_measure_item, [:record, record])

    current = get_in(normalized, ["context_receipt", "record_byte_cost"])

    cond do
      current == measured ->
        {normalized, measured}

      MapSet.member?(seen, measured) ->
        flunk("context record cost did not converge: revisited #{measured}")

      true ->
        normalized
        |> put_in(["context_receipt", "record_byte_cost"], measured)
        |> do_resolve_record_cost(MapSet.put(seen, measured))
    end
  end

  defp enormous_map(seed) do
    Enum.reduce(1..4_096, seed, fn index, map ->
      Map.put(map, "unexpected-#{index}", index)
    end)
  end

  # Concept: run one piece of work and report both what it answered and how many
  # times it hashed.
  #
  # Technical depth: a process cannot be its own `:call` tracer -- the VM
  # delivers nothing -- so tracing this process and then working in it produced
  # an empty mailbox whatever the implementation did, and every refutation over
  # it was vacuous. The work therefore runs in a child whose tracer is this
  # process. The child is awaited to `:normal` before the mailbox is counted, so
  # the count covers the whole call rather than whatever had been delivered by
  # the time the answer arrived.
  defp hash_calls(work) do
    parent = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        result = work.()
        _ = :erlang.trace(self(), false, [:call])
        send(parent, {reference, result})
      end)

    assert_receive {^reference, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    {result, count_hash_traces(pid)}
  end

  defp count_hash_traces(pid, count \\ 0) do
    receive do
      {:trace, ^pid, :call, {:crypto, :hash, _arguments}} -> count_hash_traces(pid, count + 1)
    after
      0 -> count
    end
  end

  defp trace_hash_calls(enabled) do
    flag = if enabled, do: true, else: false
    :erlang.trace_pattern({:crypto, :hash, 2}, flag, [:local])
  end

  defp dynamic_apply(module, function, arguments), do: apply(module, function, arguments)

  defp stop_runtime(runtime) do
    if Runtime.alive?(runtime), do: Loopex.stop(runtime)
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end
end

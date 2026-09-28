defmodule LoopexComposition.Ephemeral.ObservationBoundsTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  @uint64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844

  defmodule Policy do
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false
    @uint64_max 18_446_744_073_709_551_615
    @observed_max 55_340_232_221_128_654_844

    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create"),
      do: {:ok, "observation-bounds-session"}

    def attach(runtime, "observation-bounds-session", after_event_sequence: 0) do
      Process.put(:sequence, 0)
      Process.put(:run_index, 0)
      Process.put(:events, [])

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "observation-bounds-session",
         attachment_id: "bounds-attachment",
         incarnation_id: "bounds-incarnation",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "observation-bounds-session"),
      do:
        {:ok,
         %{
           status: :active,
           owner_epoch: 0,
           active_run_id: nil,
           pending_work_ids: [],
           cleanup_grace_ms: 5_000
         }}

    def command(_attachment, %{type: :prompt} = command) do
      index = Process.get(:run_index) + 1
      Process.put(:run_index, index)

      run_id =
        case command.content do
          "run-id:256" -> String.duplicate("r", 256)
          "run-id:257" -> String.duplicate("r", 257)
          _ -> "bounds-run-#{index}"
        end

      Process.put(:current_run_id, run_id)

      enqueue(%{
        :kind => "user.message_appended",
        "command_id" => command.command_id,
        "run_id" => run_id,
        "content" => command.content
      })

      case command.content do
        "tools:" <> count_text ->
          {count, ""} = Integer.parse(count_text)

          unless count == 0 do
            enqueue(%{
              :kind => "assistant.message_appended",
              "run_id" => run_id,
              "content" => "tools requested"
            })

            for number <- 1..count do
              enqueue(%{
                :kind => "tool.finished",
                "run_id" => run_id,
                "tool_id" => "tool-#{number}",
                "outcome" => "completed"
              })
            end
          end

          finish(run_id, %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})

        "bound-max" ->
          finish(run_id, bound(@observed_max, @uint64_max, @uint64_max))

        "observed-over" ->
          finish(run_id, bound(@observed_max + 1, @uint64_max, 5_000))

        "limit-over" ->
          finish(run_id, bound(@observed_max, @uint64_max + 1, 5_000))

        "grace-over" ->
          finish(run_id, bound(@observed_max, @uint64_max, @uint64_max + 1))

        "grace-negative" ->
          finish(run_id, bound(@observed_max, @uint64_max, -1))

        "answer:" <> count_text ->
          {count, ""} = Integer.parse(count_text)

          enqueue(%{
            :kind => "assistant.message_appended",
            "run_id" => run_id,
            "content" => String.duplicate("a", count)
          })

          finish(run_id, %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})

        "definition:" <> count_text ->
          {count, ""} = Integer.parse(count_text)

          enqueue(%{
            :kind => "tool.finished",
            "run_id" => run_id,
            "tool_id" => String.duplicate("d", count),
            "outcome" => "completed"
          })

          finish(run_id, %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})

        "question-tool:" <> count_text ->
          {count, ""} = Integer.parse(count_text)

          enqueue(%{
            :kind => "interaction.requested",
            "run_id" => run_id,
            "interaction_id" => "bounds-interaction",
            "turn" => 1,
            "tool_call_id" => String.duplicate("c", count),
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => 1_800_000_000
          })

        "reconciliation:" <> count_text ->
          {count, ""} = Integer.parse(count_text)

          finish(run_id, %{
            "outcome" => "outcome_unknown",
            "reconciliation_ref" => String.duplicate("q", count),
            "cleanup_grace_ms" => 5_000
          })

        "run-id:" <> _ ->
          finish(run_id, %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})
      end

      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :abort} = command) do
      finish(Process.get(:current_run_id), %{
        "outcome" => "cancelled",
        "cleanup_grace_ms" => 5_000
      })

      {:accepted, command.command_id}
    end

    def next_event(_attachment) do
      case Process.get(:events) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          {:error, :empty}
      end
    end

    defp bound(observed, limit, grace),
      do: %{
        "outcome" => "bound_reached",
        "bound" => "token_budget",
        "observed" => observed,
        "declared_limit" => limit,
        "accounting_source" => "reported",
        "cleanup_grace_ms" => grace
      }

    defp finish(run_id, details),
      do: enqueue(Map.merge(%{:kind => "run.finished", "run_id" => run_id}, details))

    defp enqueue(event) do
      sequence = Process.get(:sequence) + 1
      Process.put(:sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-observation-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "text projection preserves UTF-8 at the 65,536-byte boundary" do
    ascii_limit = String.duplicate("a", 65_536)
    multibyte_limit = String.duplicate("a", 65_534) <> "é"
    split_multibyte = String.duplicate("a", 65_535) <> "é"
    split_prefix = String.duplicate("a", 65_535)

    assert {^ascii_limit, false} = SessionOwner.text_projection_probe(ascii_limit)
    assert {^multibyte_limit, false} = SessionOwner.text_projection_probe(multibyte_limit)
    assert {^split_prefix, true} = SessionOwner.text_projection_probe(split_multibyte)

    assert {^ascii_limit, true} =
             SessionOwner.text_projection_probe(String.duplicate("a", 65_537))
  end

  test "assistant answer and history share the exact text byte ceiling", %{tmp: tmp} do
    session = start_private_session(tmp)

    assert {:ok, %{text: at_limit, text_truncated: false}} =
             Ephemeral.ask(session, "answer:65536")

    assert byte_size(at_limit) == 65_536

    assert {:ok, %{text: over_limit, text_truncated: true}} =
             Ephemeral.ask(session, "answer:65537")

    assert over_limit == at_limit
    assert {:ok, %{entries: entries}} = Ephemeral.history(session)

    assert [%{text: ^at_limit, text_truncated: false}, %{text: ^over_limit, text_truncated: true}] =
             Enum.filter(entries, &(&1.role == :assistant))

    assert :ok = Ephemeral.stop_session(session)
  end

  test "run and resolved definition identifiers enforce their own byte ceilings", %{tmp: tmp} do
    session = start_private_session(tmp)

    assert {:ok, %{run_id: run_id}} = Ephemeral.ask(session, "run-id:256")
    assert byte_size(run_id) == 256

    assert {:ok, %{tools: [%{tool_id: definition_id}]}} =
             Ephemeral.ask(session, "definition:128")

    assert byte_size(definition_id) == 128
    assert :ok = Ephemeral.stop_session(session)

    for prompt <- ["run-id:257", "definition:129"] do
      cwd = Path.join(tmp, prompt)
      File.mkdir!(cwd)
      assert_run_ending_unproved(start_private_session(cwd), prompt)
    end
  end

  test "pending tool-call identifiers admit 65,536 bytes and refuse 65,537", %{tmp: tmp} do
    session = start_private_session(tmp)

    assert {:error, {:interaction_pending, %{"tool_call_id" => call_id}}} =
             Ephemeral.ask(session, "question-tool:65536")

    assert byte_size(call_id) == 65_536
    assert :ok = Ephemeral.stop_session(session)

    cwd = Path.join(tmp, "question-over")
    File.mkdir!(cwd)
    assert_run_ending_unproved(start_private_session(cwd), "question-tool:65537")
  end

  test "the reconciliation detail identifier admits 1,024 bytes and refuses 1,025", %{
    tmp: tmp
  } do
    session = start_private_session(tmp)

    assert {:error, {:run, :outcome_unknown, %{details: %{"reconciliation_ref" => ref}}}} =
             Ephemeral.ask(session, "reconciliation:1024")

    assert byte_size(ref) == 1_024
    assert {:error, {:cleanup_unproved, %{pending: pending}}} = Ephemeral.stop_session(session)
    assert :effect_cleanup in pending

    cwd = Path.join(tmp, "reconciliation-over")
    File.mkdir!(cwd)
    assert_run_ending_unproved(start_private_session(cwd), "reconciliation:1025")
  end

  test "history and tool projections cut at 256 entries and retain the newest entries", %{
    tmp: tmp
  } do
    session = start_private_session(tmp)

    assert {:ok, %{tools: tools, tools_truncated: false}} =
             Ephemeral.ask(session, "tools:254")

    assert length(tools) == 254
    assert {:ok, %{entries: entries, truncated: false}} = Ephemeral.history(session)
    assert length(entries) == 256
    assert hd(entries) == %{role: :user, text: "tools:254", text_truncated: false}
    assert List.last(entries) == %{role: :tool, tool_id: "tool-254", outcome: "completed"}

    assert {:ok, %{tools: [], tools_truncated: false}} = Ephemeral.ask(session, "tools:0")
    assert {:ok, %{entries: entries, truncated: true}} = Ephemeral.history(session)
    assert length(entries) == 256
    assert hd(entries) == %{role: :assistant, text: "tools requested", text_truncated: false}
    assert List.last(entries) == %{role: :user, text: "tools:0", text_truncated: false}

    assert {:ok, %{tools: tools, tools_truncated: false}} =
             Ephemeral.ask(session, "tools:256")

    assert length(tools) == 256
    assert hd(tools) == %{tool_id: "tool-1", outcome: "completed"}
    assert List.last(tools) == %{tool_id: "tool-256", outcome: "completed"}

    assert {:ok, %{tools: tools, tools_truncated: true}} =
             Ephemeral.ask(session, "tools:257")

    assert length(tools) == 256
    assert hd(tools) == %{tool_id: "tool-2", outcome: "completed"}
    assert List.last(tools) == %{tool_id: "tool-257", outcome: "completed"}

    assert {:ok, %{entries: entries, truncated: true}} = Ephemeral.history(session)
    assert length(entries) == 256
    assert hd(entries) == %{role: :tool, tool_id: "tool-2", outcome: "completed"}
    assert List.last(entries) == %{role: :tool, tool_id: "tool-257", outcome: "completed"}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "terminal unsigned-64-bit and observed-usage maxima remain exact integers", %{tmp: tmp} do
    session = start_private_session(tmp)

    assert {:error,
            {:run, :bound_reached,
             %{
               details: %{
                 "observed" => @observed_max,
                 "declared_limit" => @uint64_max,
                 "cleanup_grace_ms" => @uint64_max
               }
             }}} = Ephemeral.ask(session, "bound-max")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "out-of-domain terminal numeric members never become public observations", %{tmp: tmp} do
    for prompt <- ~w(observed-over limit-over grace-over grace-negative) do
      cwd = Path.join(tmp, prompt)
      File.mkdir!(cwd)
      session = start_private_session(cwd)

      assert {:error,
              {:cleanup_unproved,
               %{ending: :none, pending: [:run_ending], root: root, root_ownership: :owned}}} =
               Ephemeral.ask(session, prompt)

      assert is_binary(root)
      assert File.dir?(root)
      assert {:error, :session_unavailable} = Ephemeral.last_result(session)
    end
  end

  defp assert_run_ending_unproved(session, prompt) do
    assert {:error,
            {:cleanup_unproved,
             %{ending: :none, pending: [:run_ending], root: root, root_ownership: :owned}}} =
             Ephemeral.ask(session, prompt)

    assert is_binary(root)
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.last_result(session)
  end

  defp start_private_session(tmp) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "observation-bounds-workspace",
        "revision" => nil,
        "packs" => []
      })

    test = self()

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 60_000,
      test_facade: Facade,
      test_seams: %{
        temp_root: %{tmp: fn -> tmp end},
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(test, {:group_drain, executor, instance})
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end
      }
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end
end

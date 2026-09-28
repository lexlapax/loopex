defmodule LoopexCli.AskProjectionTest do
  use ExUnit.Case, async: true

  alias LoopexCli.{Ask, AskResult}

  @uint64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844

  test "every outcome and profile emits one closed JSON object with public source order" do
    cases = [
      {:completed, 0, %{"cleanup_grace_ms" => @uint64_max},
       %{"cleanup_grace_ms" => Integer.to_string(@uint64_max)}},
      {:failed, 2,
       %{
         "reason" => nil,
         "failure" => %{
           "category" => "context_budget_exceeded",
           "retryable" => false,
           "dimension" => "context_tokens",
           "observed" => 9_007_199_254_740_993,
           "limit" => @uint64_max,
           "private" => "not public"
         },
         "cleanup_grace_ms" => 7
       },
       %{
         "reason" => nil,
         "failure" => %{
           "category" => "context_budget_exceeded",
           "retryable" => false,
           "dimension" => "context_tokens",
           "observed" => "9007199254740993",
           "limit" => Integer.to_string(@uint64_max)
         },
         "cleanup_grace_ms" => "7"
       }},
      {:bound_reached, 3,
       %{
         "bound" => "token_budget",
         "observed" => @observed_max,
         "declared_limit" => @uint64_max,
         "accounting_source" => nil,
         "cleanup_grace_ms" => 7
       },
       %{
         "bound" => "token_budget",
         "observed" => Integer.to_string(@observed_max),
         "declared_limit" => Integer.to_string(@uint64_max),
         "accounting_source" => nil,
         "cleanup_grace_ms" => "7"
       }},
      {:outcome_unknown, 4, %{"reconciliation_ref" => "ref-1", "cleanup_grace_ms" => 7},
       %{"reconciliation_ref" => "ref-1", "cleanup_grace_ms" => "7"}},
      {:cancelled, 5, %{"cleanup_grace_ms" => 7}, %{"cleanup_grace_ms" => "7"}}
    ]

    for {profile, cleanup, expected_cleanup} <-
          [{:ephemeral, :proved, %{"proved" => true}}, {:durable, :durable, nil}],
        {outcome, status, details, expected_details} <- cases do
      source = source(profile, outcome, details)

      ending =
        if outcome == :completed,
          do: {:ok, source},
          else: {:error, {:run, outcome, source}}

      assert %{status: ^status, stderr: ""} = result = AskResult.render(ending, cleanup, :json)

      assert object(result) == public_object(profile, outcome, expected_cleanup, expected_details)
    end

    for {profile, cleanup, expected_cleanup} <-
          [{:ephemeral, :proved, %{"proved" => true}}, {:durable, :durable, nil}] do
      snapshot =
        source(profile, :no_ending, %{})
        |> Map.drop([:outcome, :details])
        |> Map.put(:run_id, nil)
        |> Map.put(:waited_ms, @uint64_max)

      assert %{status: 6, stderr: ""} =
               result =
               AskResult.render({:error, {:timeout, snapshot}}, cleanup, :json)

      assert object(result) ==
               public_object(profile, :no_ending, expected_cleanup, %{
                 "reason" => "timeout",
                 "waited_ms" => Integer.to_string(@uint64_max)
               })
               |> Map.put("run_id", nil)
    end
  end

  test "text mode keeps failed-run text off stdout and reports tools in public order" do
    source =
      source(:durable, :failed, %{
        "reason" => "model_call_failed",
        "failure" => nil,
        "cleanup_grace_ms" => 1
      })

    assert AskResult.render({:error, {:run, :failed, source}}, :durable, :text) == %{
             status: 2,
             stdout: "",
             stderr: "tool denied null\ntool completed \"loopex.read\"\nending failed\n"
           }
  end

  test "a stop cleanup snapshot replaces a provisional worker result without leaking private fields" do
    parent = self()

    snapshot =
      source(:ephemeral, :no_ending, %{})
      |> Map.drop([:outcome, :details])
      |> Map.merge(%{
        session_id: "selected-session",
        run_id: nil,
        text: "partial answer",
        tools: [%{tool_id: nil, outcome: "failed", private: "not public"}],
        shadowed_skills: ["user:chosen"],
        waited_ms: 9_007_199_254_740_993
      })

    cleanup = %{
      root: "/tmp/retained\n",
      root_ownership: :unknown,
      pending: [:effect_cleanup, :session_subtree, :root_removal],
      ending: {:error, {:session_unavailable, snapshot}},
      private: "not public"
    }

    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--cwd", "/workspace", "--output", "json", "hello"],
        cwd: fn -> flunk("explicit cwd must be used") end,
        resolve_path: fn "/workspace" -> {:ok, "/workspace"} end,
        directory_identity: fn "/workspace" -> {:ok, {1, 2}} end,
        discard_credential: fn -> :ok end,
        quiet_logger: fn -> :ok end,
        install_interrupt: fn ^parent, _reference -> {:ok, parent} end,
        signal_manager: fn -> parent end,
        handler_live: fn _, _ -> true end,
        interrupt_phase: fn _, _ -> :idle end,
        finish_interrupt: fn _, _ -> {:ok, :ordinary} end,
        start_session: fn _ -> {:ok, :opaque_session} end,
        ask: fn _, _ -> {:ok, %{private: "stale worker answer"}} end,
        stop_session: fn :opaque_session ->
          send(parent, :stop_completed)
          {:error, {:cleanup_unproved, cleanup}}
        end
      )

    assert_receive :stop_completed

    assert %{status: 6, stderr: stderr} = result

    assert stderr ==
             "loopex: cleanup_unproved root=\"/tmp/retained\\n\" ownership=unknown pending=effect_cleanup,session_subtree,root_removal\n"

    assert object(result) == %{
             "schema" => "loopex.ask/1",
             "session_id" => "selected-session",
             "run_id" => nil,
             "profile" => "ephemeral",
             "outcome" => "no_ending",
             "text" => "partial answer",
             "text_truncated" => false,
             "tools" => [%{"tool_id" => nil, "outcome" => "failed"}],
             "tools_truncated" => false,
             "shadowed_skills" => ["user:chosen"],
             "cleanup" => %{
               "proved" => false,
               "root" => "/tmp/retained\n",
               "root_ownership" => "unknown",
               "pending" => ["effect_cleanup", "session_subtree", "root_removal"]
             },
             "details" => %{"reason" => "session_unavailable", "waited_ms" => "9007199254740993"}
           }
  end

  defp source(profile, outcome, details) do
    %{
      profile: profile,
      outcome: outcome,
      session_id: "session-1",
      run_id: "run-1",
      text: "last\nanswer",
      text_truncated: false,
      tools: [
        %{tool_id: nil, outcome: "denied", private: "not public"},
        %{tool_id: "loopex.read", outcome: "completed", private: "not public"}
      ],
      tools_truncated: false,
      shadowed_skills: ["user:alpha", "user:omega"],
      details: Map.put(details, "private", "not public"),
      private: "not public"
    }
  end

  defp public_object(profile, outcome, cleanup, details) do
    %{
      "schema" => "loopex.ask/1",
      "session_id" => "session-1",
      "run_id" => "run-1",
      "profile" => Atom.to_string(profile),
      "outcome" => Atom.to_string(outcome),
      "text" => "last\nanswer",
      "text_truncated" => false,
      "tools" => [
        %{"tool_id" => nil, "outcome" => "denied"},
        %{"tool_id" => "loopex.read", "outcome" => "completed"}
      ],
      "tools_truncated" => false,
      "shadowed_skills" => ["user:alpha", "user:omega"],
      "cleanup" => cleanup,
      "details" => details
    }
  end

  defp object(%{stdout: stdout}) do
    assert [json, ""] = String.split(stdout, "\n")
    JSON.decode!(json)
  end
end

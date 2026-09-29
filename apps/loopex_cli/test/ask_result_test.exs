defmodule LoopexCli.AskResultTest do
  use ExUnit.Case, async: true
  alias LoopexCli.AskResult

  test "completed ephemeral JSON has one closed object and one LF" do
    observation = %{
      profile: :ephemeral,
      outcome: :completed,
      session_id: "session-1",
      run_id: "run-1",
      text: "answer",
      text_truncated: false,
      tools: [%{tool_id: "loopex.read", outcome: "completed", secret: "drop"}],
      tools_truncated: false,
      shadowed_skills: [],
      details: %{"cleanup_grace_ms" => 5_000, "private" => "drop"},
      private: "drop"
    }

    assert %{status: 0, stdout: stdout, stderr: ""} =
             AskResult.render({:ok, observation}, :proved, :json)

    assert [json, ""] = String.split(stdout, "\n")

    assert JSON.decode!(json) == %{
             "schema" => "loopex.ask/1",
             "session_id" => "session-1",
             "run_id" => "run-1",
             "profile" => "ephemeral",
             "outcome" => "completed",
             "text" => "answer",
             "text_truncated" => false,
             "tools" => [%{"tool_id" => "loopex.read", "outcome" => "completed"}],
             "tools_truncated" => false,
             "shadowed_skills" => [],
             "cleanup" => %{"proved" => true},
             "details" => %{"cleanup_grace_ms" => "5000"}
           }
  end

  test "text mode emits only completed answer on stdout and bounded summaries on stderr" do
    observation = %{
      profile: :ephemeral,
      outcome: :completed,
      session_id: "session-1",
      run_id: "run-1",
      text: "answer\n",
      text_truncated: false,
      tools: [%{tool_id: nil, outcome: "denied"}, %{tool_id: "id\nquote\"", outcome: "completed"}],
      tools_truncated: false,
      shadowed_skills: [],
      details: %{"cleanup_grace_ms" => 5_000}
    }

    assert AskResult.render({:ok, observation}, :proved, :text) == %{
             status: 0,
             stdout: "answer\n\n",
             stderr: "tool denied null\ntool completed \"id\\nquote\\\"\"\nending completed\n"
           }
  end

  test "a durable no-ending snapshot renders status 6 and null cleanup" do
    snapshot = %{
      profile: :durable,
      session_id: "session-2",
      run_id: nil,
      text: "",
      text_truncated: false,
      tools: [],
      tools_truncated: false,
      shadowed_skills: [],
      waited_ms: 18_446_744_073_709_551_615
    }

    assert %{status: 6, stderr: "", stdout: json} =
             AskResult.render({:error, {:timeout, snapshot}}, :durable, :json)

    assert JSON.decode!(String.trim_trailing(json, "\n")) == %{
             "schema" => "loopex.ask/1",
             "session_id" => "session-2",
             "run_id" => nil,
             "profile" => "durable",
             "outcome" => "no_ending",
             "text" => "",
             "text_truncated" => false,
             "tools" => [],
             "tools_truncated" => false,
             "shadowed_skills" => [],
             "cleanup" => nil,
             "details" => %{"reason" => "timeout", "waited_ms" => "18446744073709551615"}
           }

    assert AskResult.render({:error, {:timeout, snapshot}}, :durable, :text) == %{
             status: 6,
             stdout: "",
             stderr: "ending no_ending timeout\n"
           }

    known = %{snapshot | run_id: "run-known"}

    assert %{status: 6, stdout: known_json} =
             AskResult.render({:error, {:timeout, known}}, :durable, :json)

    assert [known_object, ""] = String.split(known_json, "\n")
    assert JSON.decode!(known_object)["run_id"] == "run-known"

    for value <- [9_007_199_254_740_992, 9_007_199_254_740_993] do
      %{stdout: precise_json} =
        AskResult.render({:error, {:timeout, %{snapshot | waited_ms: value}}}, :durable, :json)

      assert JSON.decode!(String.trim_trailing(precise_json, "\n"))["details"]["waited_ms"] ==
               Integer.to_string(value)
    end
  end

  test "an ephemeral session-loss snapshot needs its matching unproved cleanup" do
    snapshot = %{
      profile: :ephemeral,
      session_id: "session-1",
      run_id: nil,
      text: "",
      text_truncated: false,
      tools: [],
      tools_truncated: false,
      shadowed_skills: [],
      waited_ms: 7
    }

    ending = {:error, {:session_unavailable, snapshot}}

    cleanup = %{
      root: "/temporary/retained",
      root_ownership: :owned,
      pending: [:run_ending],
      ending: ending
    }

    assert AskResult.render(ending, :proved, :json) == AskResult.diagnostic(:command_failed)

    assert AskResult.render(ending, {:unproved, %{cleanup | ending: :none}}, :json) ==
             AskResult.diagnostic(:command_failed)

    assert %{status: 6, stdout: json} = AskResult.render(ending, {:unproved, cleanup}, :json)
    assert JSON.decode!(String.trim_trailing(json, "\n"))["cleanup"]["proved"] == false
  end

  test "each non-completed terminal has its own status and closed detail members" do
    max = 18_446_744_073_709_551_615
    observed_max = 55_340_232_221_128_654_844

    cases = [
      {:failed, 2,
       %{"reason" => "model_call_failed", "failure" => nil, "cleanup_grace_ms" => max},
       %{
         "reason" => "model_call_failed",
         "failure" => nil,
         "cleanup_grace_ms" => Integer.to_string(max)
       }},
      {:failed, 2,
       %{
         "reason" => nil,
         "failure" => %{
           "category" => "context_budget_exceeded",
           "retryable" => false,
           "dimension" => "context_tokens",
           "observed" => observed_max,
           "limit" => max,
           "private" => "drop"
         },
         "cleanup_grace_ms" => 1
       },
       %{
         "reason" => nil,
         "failure" => %{
           "category" => "context_budget_exceeded",
           "retryable" => false,
           "dimension" => "context_tokens",
           "observed" => Integer.to_string(observed_max),
           "limit" => Integer.to_string(max)
         },
         "cleanup_grace_ms" => "1"
       }},
      {:bound_reached, 3,
       %{
         "bound" => "token_budget",
         "observed" => observed_max,
         "declared_limit" => max,
         "accounting_source" => "estimated",
         "cleanup_grace_ms" => 1
       },
       %{
         "bound" => "token_budget",
         "observed" => Integer.to_string(observed_max),
         "declared_limit" => Integer.to_string(max),
         "accounting_source" => "estimated",
         "cleanup_grace_ms" => "1"
       }},
      {:outcome_unknown, 4, %{"reconciliation_ref" => "ref-1", "cleanup_grace_ms" => 1},
       %{"reconciliation_ref" => "ref-1", "cleanup_grace_ms" => "1"}},
      {:cancelled, 5, %{"cleanup_grace_ms" => 1}, %{"cleanup_grace_ms" => "1"}}
    ]

    for {outcome, status, details, expected} <- cases do
      observation = observation(:durable, outcome, details)

      assert %{status: ^status, stderr: "", stdout: json} =
               AskResult.render({:error, {:run, outcome, observation}}, :durable, :json)

      object = JSON.decode!(String.trim_trailing(json, "\n"))
      assert object["outcome"] == Atom.to_string(outcome)
      assert object["details"] == expected
      assert object["cleanup"] == nil

      assert AskResult.render({:error, {:run, outcome, observation}}, :durable, :text) ==
               %{status: status, stdout: "", stderr: "ending #{outcome}\n"}
    end
  end

  test "deadline preflight failure keeps its fixed nullable failure members" do
    failure = %{
      "category" => "deadline_preflight_failed",
      "retryable" => false,
      "dimension" => nil,
      "observed" => nil,
      "limit" => nil
    }

    observation =
      observation(:ephemeral, :failed, %{
        "reason" => nil,
        "failure" => failure,
        "cleanup_grace_ms" => 1
      })

    %{stdout: json} = AskResult.render({:error, {:run, :failed, observation}}, :proved, :json)

    assert JSON.decode!(String.trim_trailing(json, "\n"))["details"] == %{
             "reason" => nil,
             "failure" => failure,
             "cleanup_grace_ms" => "1"
           }
  end

  test "unproved cleanup retains only bounded public root and reached obligations" do
    snapshot = Map.merge(observation(:ephemeral, :completed, %{}), %{run_id: nil, waited_ms: 0})
    ending = {:error, {:session_unavailable, snapshot}}

    cleanup = %{
      root: "/temporary/α\n",
      root_ownership: :unknown,
      pending: [:run_ending, :process_groups, :root_removal],
      ending: ending,
      cause: :private
    }

    root_line =
      "loopex: cleanup_unproved root=\"/temporary/α\\n\" ownership=unknown pending=run_ending,process_groups,root_removal\n" <>
        "loopex: Session cleanup is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above; do not remove an unverified path.\n"

    assert %{status: 6, stdout: json, stderr: ^root_line} =
             AskResult.render(
               ending,
               {:unproved, cleanup},
               :json
             )

    object = JSON.decode!(String.trim_trailing(json, "\n"))

    assert object["cleanup"] == %{
             "proved" => false,
             "root" => "/temporary/α\n",
             "root_ownership" => "unknown",
             "pending" => ["run_ending", "process_groups", "root_removal"]
           }

    assert object["details"] == %{"reason" => "session_unavailable", "waited_ms" => "0"}

    assert AskResult.render(
             ending,
             {:unproved, cleanup},
             :text
           ) ==
             %{
               status: 6,
               stdout: "",
               stderr: "ending no_ending session_unavailable\n" <> root_line
             }

    assert AskResult.render(:none, {:unproved, cleanup}, :json) ==
             %{status: 1, stdout: "", stderr: root_line}

    assert AskResult.render(:none, :proved, :json) == AskResult.diagnostic(:session_unavailable)
  end

  test "only a pre-claim subtree failure can render an unnamed root" do
    preclaim = %{root: nil, root_ownership: :unknown, pending: [:session_subtree], ending: :none}

    assert AskResult.render(:none, {:unproved, preclaim}, :json) == %{
             status: 1,
             stdout: "",
             stderr:
               "loopex: cleanup_unproved root=null ownership=unknown pending=session_subtree\n" <>
                 "loopex: Loopex could not confirm that the temporary session stopped, and no root path is known. Before running ask again, make sure the previous ask process has exited; do not remove a guessed directory.\n"
           }

    assert AskResult.render(:none, {:unproved, %{preclaim | root_ownership: :owned}}, :json) ==
             AskResult.diagnostic(:command_failed)

    assert AskResult.render(:none, {:unproved, %{preclaim | pending: [:root_removal]}}, :json) ==
             AskResult.diagnostic(:command_failed)

    assert AskResult.render(:none, {:unproved, Map.delete(preclaim, :ending)}, :json) ==
             AskResult.diagnostic(:command_failed)

    terminal =
      {:error,
       {:run, :cancelled, observation(:ephemeral, :cancelled, %{"cleanup_grace_ms" => 10})}}

    assert AskResult.render(terminal, {:unproved, preclaim}, :json) ==
             AskResult.diagnostic(:command_failed)
  end

  test "unproved terminal cleanup keeps the run status and appends its root line" do
    observation = %{
      observation(:ephemeral, :cancelled, %{"cleanup_grace_ms" => 10})
      | tools: [%{tool_id: "loopex.read", outcome: "cancelled"}]
    }

    ending = {:error, {:run, :cancelled, observation}}
    cleanup = %{root: "/kept", root_ownership: :owned, pending: [:root_removal], ending: ending}

    line =
      "loopex: cleanup_unproved root=\"/kept\" ownership=owned pending=root_removal\n" <>
        "loopex: Removal of the temporary root is unconfirmed. Before running ask again, inspect the root named above and complete its cleanup only after verifying that it belongs to this session.\n"

    assert AskResult.render(
             ending,
             {:unproved, cleanup},
             :text
           ) ==
             %{
               status: 5,
               stdout: "",
               stderr: "tool cancelled \"loopex.read\"\nending cancelled\n" <> line
             }

    assert %{status: 5, stderr: ^line, stdout: json} =
             AskResult.render(
               ending,
               {:unproved, cleanup},
               :json
             )

    assert JSON.decode!(String.trim_trailing(json, "\n"))["cleanup"] == %{
             "proved" => false,
             "root" => "/kept",
             "root_ownership" => "owned",
             "pending" => ["root_removal"]
           }
  end

  test "malformed source values and unknown diagnostics never enter output" do
    huge = String.duplicate("private", 12_000)
    valid = observation(:ephemeral, :completed, %{"cleanup_grace_ms" => 1})

    invalid = [
      %{valid | text: huge},
      %{valid | text: <<255>>},
      %{valid | tools: [%{tool_id: huge, outcome: "completed"}]},
      %{valid | details: %{"cleanup_grace_ms" => 0}},
      %{valid | run_id: nil}
    ]

    for observation <- invalid do
      assert AskResult.render({:ok, observation}, :proved, :json) ==
               AskResult.diagnostic(:command_failed)
    end

    assert AskResult.render({:ok, valid}, {:unproved, %{root: huge}}, :json) ==
             AskResult.diagnostic(:command_failed)

    assert AskResult.render(
             {:ok, valid},
             {:unproved,
              %{
                root: "/kept",
                root_ownership: :owned,
                pending: [:root_removal, :run_ending]
              }},
             :json
           ) == AskResult.diagnostic(:command_failed)

    assert AskResult.diagnostic({:secret, huge}) ==
             %{status: 1, stdout: "", stderr: "loopex: command_failed\n"}

    assert AskResult.diagnostic(:invalid_model) ==
             %{status: 1, stdout: "", stderr: "loopex: invalid_model\n"}
  end

  test "an empty tool projection cannot claim truncated tools" do
    observation = %{
      observation(:ephemeral, :completed, %{"cleanup_grace_ms" => 1})
      | tools: [],
        tools_truncated: true
    }

    assert AskResult.render({:ok, observation}, :proved, :json) ==
             AskResult.diagnostic(:command_failed)
  end

  test "text and tool-list boundaries admit the maximum and refuse the next byte or entry" do
    base = observation(:ephemeral, :completed, %{"cleanup_grace_ms" => 1})
    max_text = String.duplicate("x", 65_536)
    max_id = String.duplicate("i", 128)
    tool = %{tool_id: max_id, outcome: "completed"}
    full = %{base | text: max_text, tools: List.duplicate(tool, 256), tools_truncated: true}

    assert %{status: 0, stderr: "", stdout: json} =
             AskResult.render({:ok, full}, :proved, :json)

    assert [object, ""] = String.split(json, "\n")
    decoded = JSON.decode!(object)
    assert length(decoded["tools"]) == 256
    assert byte_size(decoded["text"]) == 65_536

    bad = [
      %{base | text: max_text <> "x"},
      %{base | tools: [%{tool | tool_id: max_id <> "i"}]},
      %{base | tools: List.duplicate(tool, 257)}
    ]

    for observation <- bad do
      assert AskResult.render({:ok, observation}, :proved, :json) ==
               AskResult.diagnostic(:command_failed)
    end
  end

  test "the status-one diagnostic vocabulary is closed and input-free" do
    Code.ensure_loaded!(AskResult)
    codes = ~w(
      invalid_arguments invalid_output invalid_state_root invalid_cwd invalid_model
      invalid_tools invalid_skills invalid_max_steps invalid_deadline policy_required
      invalid_policy workspace_unusable invalid_prompt_empty invalid_prompt_too_large
      invalid_prompt_invalid_utf8 skill_directories_unavailable application_start_failed
      durable_model_unsupported provider_credential_required durable_runtime_unavailable
      composition_unavailable session_create_failed session_tracking_failed attachment_failed
      resource_admission_failed skill_activation_failed session_status_failed
      prompt_submission_failed follow_reader_cleanup_unconfirmed interrupt_handler_unavailable
      runtime_cleanup_unconfirmed session_unavailable command_failed
    )

    for code <- codes do
      guidance =
        if code == "interrupt_handler_unavailable" do
          "loopex: The interrupt handler is unavailable. Before running ask again, make sure the previous ask process has exited and start a fresh command. If this repeats, repair the host's signal-handler setup.\n"
        else
          ""
        end

      assert AskResult.diagnostic(String.to_existing_atom(code)) ==
               %{status: 1, stdout: "", stderr: "loopex: #{code}\n" <> guidance}
    end
  end

  defp observation(profile, outcome, details) do
    %{
      profile: profile,
      outcome: outcome,
      session_id: "session-1",
      run_id: "run-1",
      text: "",
      text_truncated: false,
      tools: [],
      tools_truncated: false,
      shadowed_skills: ["user:local"],
      details: details
    }
  end
end

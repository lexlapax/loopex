defmodule LoopexCli.AskExitTest do
  @moduledoc """
  ## Concept

  Pins the standalone command's exit codes and final output bytes at the
  command boundary.

  ## Technical depth

  Private process seams supply public API results. The command still admits
  argv, starts and reaps its ask worker, stops its session, and selects the
  signal decision before rendering.
  """

  use ExUnit.Case, async: true

  alias LoopexCli.Ask

  @tools [%{tool_id: nil, outcome: "denied"}, %{tool_id: "read\nid", outcome: "completed"}]
  @tool_lines "tool denied null\ntool completed \"read\\nid\"\n"

  test "each terminal status has exact text and one clean JSON object" do
    cases = [
      {:completed, 0, %{"cleanup_grace_ms" => 5_000}},
      {:failed, 2,
       %{"reason" => "model_call_failed", "failure" => nil, "cleanup_grace_ms" => 5_000}},
      {:bound_reached, 3,
       %{
         "bound" => "max_turns",
         "observed" => 1,
         "declared_limit" => 1,
         "accounting_source" => nil,
         "cleanup_grace_ms" => 5_000
       }},
      {:outcome_unknown, 4, %{"reconciliation_ref" => "receipt-1", "cleanup_grace_ms" => 5_000}},
      {:cancelled, 5, %{"cleanup_grace_ms" => 5_000}}
    ]

    for {outcome, status, details} <- cases do
      observation = observation(outcome, details)

      answer =
        if outcome == :completed,
          do: {:ok, observation},
          else: {:error, {:run, outcome, observation}}

      assert %{status: ^status, stdout: text_stdout, stderr: text_stderr} =
               command(:text, answer)

      assert text_stdout == if(outcome == :completed, do: "answer\n", else: "")
      assert text_stderr == @tool_lines <> "ending #{outcome}\n"

      assert %{status: ^status, stdout: json_stdout, stderr: ""} = command(:json, answer)
      assert [encoded, ""] = String.split(json_stdout, "\n")

      assert %{
               "schema" => "loopex.ask/1",
               "profile" => "ephemeral",
               "outcome" => rendered_outcome,
               "text" => "answer",
               "tools" => [%{"tool_id" => nil, "outcome" => "denied"}, _],
               "cleanup" => %{"proved" => true}
             } = object = JSON.decode!(encoded)

      assert rendered_outcome == Atom.to_string(outcome)

      assert Map.keys(object) |> Enum.sort() ==
               ~w(cleanup details outcome profile run_id schema session_id shadowed_skills text text_truncated tools tools_truncated)
    end
  end

  test "both no-ending reasons use status six and keep stdout pure" do
    timeout = {:error, {:timeout, snapshot()}}

    assert command(:text, timeout) == %{
             status: 6,
             stdout: "",
             stderr: @tool_lines <> "ending no_ending timeout\n"
           }

    assert %{status: 6, stdout: timeout_json, stderr: ""} = command(:json, timeout)
    assert one_json(timeout_json)["details"] == %{"reason" => "timeout", "waited_ms" => "25"}

    lost = {:error, {:session_unavailable, snapshot()}}
    cleanup = cleanup(lost)

    assert command(:text, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
             stop_session: fn _ -> {:error, {:cleanup_unproved, cleanup}} end
           ) == %{
             status: 6,
             stdout: "",
             stderr:
               @tool_lines <> "ending no_ending session_unavailable\n" <> root_line(cleanup.root)
           }

    assert %{status: 6, stdout: lost_json, stderr: stderr} =
             command(:json, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
               stop_session: fn _ -> {:error, {:cleanup_unproved, cleanup}} end
             )

    assert stderr == root_line(cleanup.root)

    assert one_json(lost_json)["details"] ==
             %{"reason" => "session_unavailable", "waited_ms" => "25"}

    assert one_json(lost_json)["cleanup"] == %{
             "proved" => false,
             "root" => cleanup.root,
             "root_ownership" => "owned",
             "pending" => ["run_ending", "root_removal"]
           }
  end

  test "status one and interrupted status 130 emit no answer" do
    assert command(:json, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
             stop_session: fn _ -> {:error, :session_unavailable} end
           ) == %{status: 1, stdout: "", stderr: "loopex: session_unavailable\n"}

    assert command(:text, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
             finish_interrupt: fn _, _ -> {:ok, :interrupted} end
           ) == %{status: 130, stdout: "", stderr: @tool_lines <> "ending completed\n"}
  end

  test "hostile input and facade terms never enter status-one diagnostics" do
    secret = "SENSITIVE\nline\t" <> String.duplicate("x", 70_000)
    nested = {:private, %{token: secret, nested: [secret, %{path: "/" <> secret}]}}

    cases = [
      {fn -> command(:json, nested) end, "loopex: command_failed\n"},
      {fn ->
         command(:json, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
           start_session: fn _ -> raise secret end
         )
       end, "loopex: composition_unavailable\n"},
      {fn ->
         command(:json, {:ok, observation(:completed, %{"cleanup_grace_ms" => 5_000})},
           start_session: fn _ -> {:error, nested} end
         )
       end, "loopex: composition_unavailable\n"},
      {fn -> Ask.run(["-p", "--policy", "allow-all", "--" <> secret, "hello"], seams(nested)) end,
       "loopex: invalid_arguments\n"}
    ]

    for {invoke, diagnostic} <- cases do
      assert %{status: 1, stdout: "", stderr: ^diagnostic} = invoke.()
      refute diagnostic =~ "SENSITIVE"
    end

    bad_root = "/private/" <> secret
    retained = cleanup(:none) |> Map.put(:root, bad_root)

    assert command(:json, nested,
             stop_session: fn _ -> {:error, {:cleanup_unproved, retained}} end
           ) == %{status: 1, stdout: "", stderr: "loopex: command_failed\n"}

    root = "/private/\"\n\tcontrol"
    retained = cleanup(:none) |> Map.put(:root, root)

    assert command(:json, nested,
             stop_session: fn _ -> {:error, {:cleanup_unproved, retained}} end
           ) == %{status: 1, stdout: "", stderr: root_line(root, "run_ending,root_removal")}
  end

  defp command(mode, answer, overrides \\ []) do
    Ask.run(
      ["-p", "--policy", "allow-all", "--output", Atom.to_string(mode), "hello"],
      seams(answer, overrides)
    )
  end

  defp seams(answer, overrides \\ []) do
    manager =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(manager), do: Process.exit(manager, :kill) end)

    base = [
      cwd: fn -> {:ok, "/workspace"} end,
      resolve_path: fn path -> {:ok, path} end,
      directory_identity: fn _ -> {:ok, {1, 2}} end,
      discard_credential: fn -> :ok end,
      quiet_logger: fn -> :ok end,
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end,
      start_session: fn _ -> {:ok, :session} end,
      ask: fn _, _ -> answer end,
      stop_session: fn _ -> :ok end
    ]

    Keyword.merge(base, overrides)
  end

  defp observation(outcome, details) do
    %{
      profile: :ephemeral,
      outcome: outcome,
      session_id: "session-1",
      run_id: "run-1",
      text: "answer",
      text_truncated: false,
      tools: @tools,
      tools_truncated: false,
      shadowed_skills: [],
      details: details
    }
  end

  defp snapshot do
    observation(:completed, %{})
    |> Map.drop([:outcome, :details])
    |> Map.put(:run_id, nil)
    |> Map.put(:waited_ms, 25)
  end

  defp cleanup(ending) do
    %{
      root: "/private/retained",
      root_ownership: :owned,
      pending: [:run_ending, :root_removal],
      ending: ending
    }
  end

  defp root_line(root, pending \\ "run_ending,root_removal") do
    "loopex: cleanup_unproved root=#{JSON.encode!(root)} ownership=owned pending=#{pending}\n"
  end

  defp one_json(stdout) do
    assert [encoded, ""] = String.split(stdout, "\n")
    JSON.decode!(encoded)
  end
end

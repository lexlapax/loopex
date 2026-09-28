defmodule LoopexCli.AskEphemeralTest do
  use ExUnit.Case, async: true

  alias LoopexCli.Ask

  test "both command spellings run one embedded session and render only after stop and finish" do
    for command <- ["ask", "-p"] do
      parent = self()
      options = seams()

      result = Ask.run([command, "--policy", "allow-all", "--output", "json", "hello"], options)

      assert %{status: 0, stderr: "", stdout: stdout} = result
      assert [json, ""] = String.split(stdout, "\n")
      assert %{"outcome" => "completed", "cleanup" => %{"proved" => true}} = JSON.decode!(json)

      assert_receive {:handler_installed, ^parent, _reference}
      assert_receive {:session_started, selected}
      assert selected[:cwd] == "/verified"
      assert selected[:tools] == :coding
      assert selected[:policy] == LoopexCli.Policy.AllowAll
      assert_receive {:question_asked, "hello"}
      assert_receive :session_stopped
      assert_receive :handler_finished
    end
  end

  test "install refusal creates no session or question worker" do
    parent = self()

    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "hello"],
        seams(
          install_interrupt: fn main, reference ->
            send(parent, {:handler_refused, main, reference})
            {:error, :not_installed}
          end,
          start_session: fn _ -> flunk("session started after install refusal") end,
          ask: fn _, _ -> flunk("worker started after install refusal") end
        )
      )

    assert result == LoopexCli.AskResult.diagnostic(:interrupt_handler_unavailable)

    assert_receive {:handler_refused, ^parent, _reference}
    refute_receive :session_stopped, 0
    refute_receive {:question_asked, _}, 0
  end

  test "a failed post-install handler probe retires the handler without starting a session" do
    parent = self()

    assert Ask.run(
             ["ask", "--policy", "allow-all", "hello"],
             seams(
               handler_live: fn _, _ -> false end,
               start_session: fn _ -> flunk("session started after handler loss") end,
               finish_interrupt: fn _, _ ->
                 send(parent, :failed_probe_handler_finished)
                 {:ok, :ordinary}
               end
             )
           ) == LoopexCli.AskResult.diagnostic(:interrupt_handler_unavailable)

    assert_receive :failed_probe_handler_finished
    refute_receive :session_stopped, 0
  end

  test "a handler probe failure after startup stops before attempting handler retirement" do
    parent = self()
    probes = :atomics.new(1, signed: false)

    assert Ask.run(
             ["ask", "--policy", "allow-all", "hello"],
             seams(
               handler_live: fn _, _ -> :atomics.add_get(probes, 1, 1) == 1 end,
               ask: fn _, _ -> flunk("worker started after handler loss") end,
               finish_interrupt: fn _, _ ->
                 send(parent, :failed_session_probe_handler_finished)
                 {:ok, :ordinary}
               end
             )
           ) == LoopexCli.AskResult.diagnostic(:interrupt_handler_unavailable)

    assert_receive :session_stopped
    assert_receive :failed_session_probe_handler_finished
    refute_receive {:question_asked, _}, 0
  end

  test "the standalone logger is quieted before any session starts" do
    assert Ask.run(
             ["ask", "--policy", "allow-all", "hello"],
             seams(
               quiet_logger: fn -> {:error, :logger_unavailable} end,
               start_session: fn _ -> flunk("session started before logger suppression") end
             )
           ) == LoopexCli.AskResult.diagnostic(:composition_unavailable)
  end

  test "startup rollback retains its root when the signal decision is lost" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "hello"],
        seams(
          start_session: fn _ -> {:error, {:cleanup_unproved, cleanup_map(:none)}} end,
          finish_interrupt: fn _, _ -> {:error, :lost_reply} end,
          ask: fn _, _ -> flunk("worker started after startup rollback") end
        )
      )

    assert result == %{
             status: 1,
             stdout: "",
             stderr:
               "loopex: cleanup_unproved root=\"/tmp/ask-kept\" ownership=owned pending=session_subtree\n"
           }
  end

  test "worker creation failure stops the new session before reporting" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "hello"],
        seams(
          start_worker: fn _ -> raise "process limit" end,
          ask: fn _, _ -> flunk("worker started after creation failure") end
        )
      )

    assert result == LoopexCli.AskResult.diagnostic(:command_failed)
    assert_receive :session_stopped
    assert_receive :handler_finished
    refute_receive {:question_asked, _}, 0
  end

  test "an unmarked owner loss discards a completed worker observation" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(stop_session: fn _ -> {:error, :session_unavailable} end)
      )

    assert result == LoopexCli.AskResult.diagnostic(:session_unavailable)
  end

  test "a proof-bearing stop selects its no-ending snapshot and retained root" do
    snapshot = no_ending_snapshot()

    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(
          ask: fn _, _ -> {:ok, observation()} end,
          stop_session: fn _ ->
            {:error, {:cleanup_unproved, cleanup_map({:error, {:session_unavailable, snapshot}})}}
          end
        )
      )

    assert %{status: 6, stdout: stdout, stderr: stderr} = result

    assert %{
             "outcome" => "no_ending",
             "cleanup" => %{"proved" => false, "root" => "/tmp/ask-kept"},
             "details" => %{"reason" => "session_unavailable", "waited_ms" => "25"}
           } = JSON.decode!(String.trim_trailing(stdout, "\n"))

    assert String.contains?(stderr, "root=\"/tmp/ask-kept\"")
  end

  test "a worker cleanup map yields to successful, newer unproved, or bare stop" do
    first = cleanup_map({:ok, observation()})

    proved =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(ask: fn _, _ -> {:error, {:cleanup_unproved, first}} end)
      )

    assert %{status: 0, stderr: "", stdout: proved_json} = proved

    assert %{"outcome" => "completed", "cleanup" => %{"proved" => true}} =
             JSON.decode!(String.trim_trailing(proved_json, "\n"))

    cancelled = %{observation() | outcome: :cancelled}
    newer = %{cleanup_map({:error, {:run, :cancelled, cancelled}}) | root: "/tmp/newer-root"}

    replaced =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(
          ask: fn _, _ -> {:error, {:cleanup_unproved, first}} end,
          stop_session: fn _ -> {:error, {:cleanup_unproved, newer}} end
        )
      )

    assert %{status: 5, stdout: replaced_json, stderr: replaced_stderr} = replaced

    assert %{
             "outcome" => "cancelled",
             "cleanup" => %{"proved" => false, "root" => "/tmp/newer-root"}
           } = JSON.decode!(String.trim_trailing(replaced_json, "\n"))

    assert replaced_stderr =~ "root=\"/tmp/newer-root\""
    refute replaced_stderr =~ "/tmp/ask-kept"

    retained =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(
          ask: fn _, _ -> {:error, {:cleanup_unproved, first}} end,
          stop_session: fn _ -> {:error, :session_unavailable} end
        )
      )

    assert %{status: 0, stdout: retained_json, stderr: retained_stderr} = retained

    assert %{
             "outcome" => "completed",
             "cleanup" => %{"proved" => false, "root" => "/tmp/ask-kept"}
           } = JSON.decode!(String.trim_trailing(retained_json, "\n"))

    assert retained_stderr =~ "root=\"/tmp/ask-kept\""
  end

  test "an unproved stop with no ending names only its retained root" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(stop_session: fn _ -> {:error, {:cleanup_unproved, cleanup_map(:none)}} end)
      )

    assert result == %{
             status: 1,
             stdout: "",
             stderr:
               "loopex: cleanup_unproved root=\"/tmp/ask-kept\" ownership=owned pending=session_subtree\n"
           }
  end

  test "an ordinary timeout keeps its no-ending observation after proved stop" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(ask: fn _, _ -> {:error, {:timeout, no_ending_snapshot()}} end)
      )

    assert %{status: 6, stderr: "", stdout: json} = result

    assert %{
             "outcome" => "no_ending",
             "cleanup" => %{"proved" => true},
             "details" => %{"reason" => "timeout", "waited_ms" => "25"}
           } = JSON.decode!(String.trim_trailing(json, "\n"))
  end

  test "a bare worker session loss cannot invent a proved no-ending result" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(ask: fn _, _ -> {:error, {:session_unavailable, no_ending_snapshot()}} end)
      )

    assert result == LoopexCli.AskResult.diagnostic(:command_failed)
  end

  test "worker death without a result stops the session and invents no ending" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "hello"],
        seams(ask: fn _, _ -> exit(:normal) end)
      )

    assert result == LoopexCli.AskResult.diagnostic(:session_unavailable)
  end

  test "a finish decision interrupted after a completed worker result suppresses text" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "hello"],
        seams(finish_interrupt: fn _, _ -> {:ok, :interrupted} end)
      )

    assert %{status: 130, stdout: "", stderr: "ending completed\n"} = result
  end

  test "an exact notice stops a blocked worker, reaps it, and exits 130" do
    parent = self()
    phase = :atomics.new(1, [])

    options =
      seams(
        ask: fn _, _ ->
          send(parent, :worker_entered)

          receive do
            :never -> :ok
          end
        end,
        finish_interrupt: fn _, _ -> {:ok, :interrupted} end,
        interrupt_phase: fn _, _ ->
          if :atomics.get(phase, 1) == 1, do: :stopping, else: :idle
        end
      )

    runner =
      spawn(fn ->
        send(
          parent,
          {:runner_result, self(), Ask.run(["ask", "--policy", "allow-all", "hello"], options)}
        )
      end)

    assert_receive {:handler_installed, ^runner, reference}, 1_000
    assert_receive :worker_entered, 1_000
    :atomics.put(phase, 1, 1)
    send(runner, {options[:signal_manager].(), reference, :interrupt})
    assert_receive :session_stopped, 1_000
    assert_receive {:runner_result, ^runner, %{status: 130, stdout: "", stderr: ""}}, 2_000
  end

  test "copied notices cannot starve the provisional worker reap deadline" do
    parent = self()

    options =
      seams(
        worker_after_send: fn ->
          send(parent, {:worker_parked, self()})

          receive do
            :never -> :ok
          end
        end,
        interrupt_phase: fn _, _ -> :idle end,
        halt: fn status ->
          send(parent, {:hard_halt, status})
          exit(:test_halt)
        end
      )

    {runner, _runner_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:runner_result, self(), Ask.run(["ask", "--policy", "allow-all", "hello"], options)}
        )
      end)

    assert_receive {:handler_installed, ^runner, reference}, 1_000
    assert_receive {:worker_parked, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    manager = options[:signal_manager].()

    flood =
      spawn(fn ->
        flood_notices(runner, manager, reference)
      end)

    try do
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_500
    after
      if Process.alive?(flood), do: Process.exit(flood, :kill)
      if Process.alive?(runner), do: Process.exit(runner, :kill)
    end
  end

  defp flood_notices(runner, manager, reference) do
    send(runner, {manager, reference, :interrupt})
    Process.sleep(1)
    flood_notices(runner, manager, reference)
  end

  defp seams(overrides \\ []) do
    parent = self()

    manager =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(manager), do: Process.exit(manager, :kill)
    end)

    base = [
      cwd: fn -> {:ok, "/current"} end,
      resolve_path: fn _ -> {:ok, "/verified"} end,
      directory_identity: fn _ -> {:ok, {1, 2}} end,
      discard_credential: fn -> :ok end,
      quiet_logger: fn -> :ok end,
      start_session: fn selected ->
        send(parent, {:session_started, selected})
        {:ok, :fixture_session}
      end,
      install_interrupt: fn main, reference ->
        send(parent, {:handler_installed, main, reference})
        {:ok, manager}
      end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      ask: fn _, prompt ->
        send(parent, {:question_asked, prompt})
        {:ok, observation()}
      end,
      stop_session: fn _ ->
        send(parent, :session_stopped)
        :ok
      end,
      finish_interrupt: fn _, _ ->
        send(parent, :handler_finished)
        {:ok, :ordinary}
      end
    ]

    Keyword.merge(base, overrides)
  end

  defp observation do
    %{
      profile: :ephemeral,
      outcome: :completed,
      session_id: "session-1",
      run_id: "run-1",
      text: "answer",
      text_truncated: false,
      tools: [],
      tools_truncated: false,
      shadowed_skills: [],
      details: %{"cleanup_grace_ms" => 5_000}
    }
  end

  test "pre-claim startup uncertainty reports an unnamed root without output" do
    result =
      Ask.run(
        ["ask", "--policy", "allow-all", "--output", "json", "hello"],
        seams(
          start_session: fn _ ->
            {:error,
             {:cleanup_unproved,
              %{
                root: nil,
                root_ownership: :unknown,
                pending: [:session_subtree],
                ending: :none
              }}}
          end,
          ask: fn _, _ -> flunk("worker started after pre-claim failure") end
        )
      )

    assert result == %{
             status: 1,
             stdout: "",
             stderr:
               "loopex: cleanup_unproved root=null ownership=unknown pending=session_subtree\n"
           }

    assert_receive :handler_finished
  end

  defp no_ending_snapshot do
    observation()
    |> Map.drop([:outcome, :details])
    |> Map.put(:run_id, nil)
    |> Map.put(:text, "")
    |> Map.put(:waited_ms, 25)
  end

  defp cleanup_map(ending) do
    %{
      root: "/tmp/ask-kept",
      root_ownership: :owned,
      pending: [:session_subtree],
      ending: ending,
      cause: nil
    }
  end
end

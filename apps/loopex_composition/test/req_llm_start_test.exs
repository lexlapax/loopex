defmodule LoopexComposition.ReqLLMStartTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @scenarios [
    :first_start,
    :host_state_table,
    :provenance_restart,
    :guards,
    :concurrent_cohorts,
    :waiter_loss,
    :service_reconciliation,
    :temporary_crash_loop,
    :worker_loss,
    :malformed_records,
    :stalled_controller,
    :queue_bound,
    :result_and_down,
    :pre_grant_service_loss,
    :empty_start_list,
    :failure_and_protocol
  ]

  for scenario <- @scenarios do
    @scenario scenario
    @tag timeout: 30_000
    test "guarded shared startup: #{scenario}" do
      root =
        Path.join(System.tmp_dir!(), "m6-req-llm-start-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      File.write!(Path.join(root, ".env"), "LOOPEX_M6_START_CANARY=must-not-load\n")

      paths =
        :code.lib_dir(:loopex_composition)
        |> to_string()
        |> Path.join("../*/ebin")
        |> Path.expand()
        |> Path.wildcard()

      fixture = Path.expand("support/req_llm_start_fixture.ex", __DIR__)

      source =
        "Code.require_file(#{inspect(fixture)}); LoopexComposition.ReqLLMStartFixture.run(#{inspect(@scenario)})"

      arguments =
        ["--erl", "+S 2:2 +SDcpu 1 +SDio 1 +A 2"] ++
          Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", source]

      # Concept: application-controller faults belong to an isolated VM.
      # Technical depth: System.cmd awaits the actual child OS process exit;
      # no held controller, application settings or shared service reaches this VM.
      assert {output, 0} =
               System.cmd("elixir", arguments,
                 cd: root,
                 stderr_to_stdout: true,
                 env:
                   Enum.map(
                     ~w(LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
                        OPENROUTER_API_KEY GH_TOKEN GITHUB_TOKEN SSLKEYLOGFILE
                        TIDEWAVE_REPL LOOPEX_M6_START_CANARY),
                     &{&1, nil}
                   ) ++ [{"ERL_CRASH_DUMP", "/dev/null"}, {"ERL_CRASH_DUMP_SECONDS", "0"}]
               )

      assert output =~ "M6_REQ_LLM_START_OK #{inspect(@scenario)}"
    end
  end
end

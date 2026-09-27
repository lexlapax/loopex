defmodule Loopex.LLM.ReqLLM.DependencyStartTest do
  use ExUnit.Case, async: false

  test "the compiled edge carries Logger but starts none of its load-only dependencies" do
    application_file =
      :code.lib_dir(:loopex_llm_reqllm)
      |> to_string()
      |> Path.join("ebin/loopex_llm_reqllm.app")

    assert {:ok, [{:application, :loopex_llm_reqllm, metadata}]} =
             :file.consult(String.to_charlist(application_file))

    applications = Keyword.fetch!(metadata, :applications)
    assert :logger in applications
    refute Enum.any?([:req_llm, :req, :finch], &(&1 in applications))
  end

  test "a fresh VM starts composition without dotenv then explicitly starts the dependency graph" do
    root =
      Path.join(System.tmp_dir!(), "m6-dependency-start-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    File.write!(Path.join(root, ".env"), "LOOPEX_M6_DOTENV_CANARY=must-not-load\n")

    # Concept: application metadata is witnessed by real automatic startup.
    # Technical depth: the fresh VM receives compiled code paths, no Mix
    # application starter. Its selected-provider variables are absent and the
    # deliberately planted dotenv value must remain absent before and after
    # explicit startup. This is not the later escript packaging witness.
    paths =
      :code.lib_dir(:loopex_llm_reqllm)
      |> to_string()
      |> Path.join("../*/ebin")
      |> Path.expand()
      |> Path.wildcard()

    source = """
    started = fn -> Enum.map(Application.started_applications(), &elem(&1, 0)) end
    ensure = fn condition -> unless condition, do: System.halt(1) end
    ensure.(Enum.all?([:req_llm, :req, :finch], &(&1 not in started.())))
    {:ok, _} = Application.ensure_all_started(:loopex_composition)
    ensure.(Enum.all?([:req_llm, :req, :finch], &(&1 not in started.())))
    ensure.(System.get_env("LOOPEX_M6_DOTENV_CANARY") == nil)
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    {:ok, _} = Application.ensure_all_started(:req_llm)
    ensure.(Enum.all?([:req_llm, :req, :finch], &(&1 in started.())))
    ensure.(System.get_env("LOOPEX_M6_DOTENV_CANARY") == nil)
    IO.puts("M6_DEPENDENCY_START_OK")
    """

    arguments =
      ["--erl", "+S 2:2 +SDcpu 1 +SDio 1 +A 2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", source]

    assert {output, 0} =
             System.cmd("elixir", arguments,
               cd: root,
               stderr_to_stdout: true,
               env:
                 Enum.map(
                   ~w(LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
                               OPENROUTER_API_KEY LOOPEX_M6_DOTENV_CANARY),
                   &{&1, nil}
                 )
             )

    assert output =~ "M6_DEPENDENCY_START_OK"
  end
end

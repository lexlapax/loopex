defmodule Loopex.LLM.ReqLLM.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_llm_reqllm,
      loopex_role: :edge,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      # These two modules are explicitly required by tests, not test selectors.
      # Current Mix warns on unclassified .exs files; no *_test.exs is ignored.
      test_ignore_filters: [
        "test/support/provider_build_fixture.exs",
        "test/support/provider_isolation_fixture.exs"
      ],
      start_permanent: Mix.env() == :prod,
      escript: [
        app: nil,
        main_module: Loopex.LLM.ReqLLM.ProviderWorker,
        name: :loopex_provider,
        path: provider_path(),
        emu_args: "+S 2:2 +SDcpu 1 +SDio 1 +A 2"
      ],
      aliases: ["escript.build": ["loopex.provider.build"]],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
  end

  # Concept: companion artifacts stay inside the caller's isolated build root.
  # Technical depth: project/0 is still being evaluated here, so supply the
  # ordinary build configuration explicitly instead of recursively asking for
  # it. The floor requires build_per_environment; Mix applies root/path and
  # target overrides with exactly the same rules as ordinary compilation.
  defp provider_path do
    [build_path: "../../_build", build_per_environment: true]
    |> Mix.Project.build_path()
    |> Path.expand()
    |> Path.join("loopex_provider")
  end

  # Concept: the reference model adapter named in the vision. It depends outward
  # on ReqLLM for provider transport and inward on core's Model behaviour; the
  # edge runs one way, and nothing in the umbrella depends on this application.
  #
  # Technical depth: the range is pinned rather than open so a provider-library
  # change is a decision instead of a refetch. `mix loopex.deps_budget` reads the
  # contract and runtime budgets and never admits this dependency into either,
  # and `mix loopex.core_only` fails if this application is resolved or started
  # in the core lane.
  defp deps do
    [
      {:req_llm, "~> 1.17.1"},
      {:loopex, in_umbrella: true},
      {:loopex_protocol, in_umbrella: true}
    ]
  end
end

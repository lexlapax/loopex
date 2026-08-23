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
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
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

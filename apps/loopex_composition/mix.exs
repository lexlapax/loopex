defmodule LoopexComposition.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_composition,
      loopex_role: :composition,
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

  def application, do: [extra_applications: []]

  # Concept: the one application permitted to name concrete adapters.
  #
  # Technical depth: a composition exists to wire a stack, so it depends on the
  # edges it composes. That is exactly what an `:edge` may not do and exactly
  # what a `:client` may not be depended on for, which is why the role exists
  # rather than either rule being widened. It declares no external dependency and
  # depends on no client and no other composition.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_store_local, in_umbrella: true},
      {:loopex_llm_reqllm, in_umbrella: true},
      {:loopex_executor_local, in_umbrella: true}
    ]
  end
end

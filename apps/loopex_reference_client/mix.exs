defmodule Loopex.ReferenceClient.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_reference_client,
      loopex_role: :client,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: []]

  # Concept: production client code may drive only the embedded core facade.
  # Concrete edges are available solely to the Workstream D composition tests.
  #
  # Technical depth: completing the exact six-application inventory makes every
  # Workstream C edge's inward core dependency explicit without adding client
  # behavior before the C rejoin checkpoint.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_store_local, in_umbrella: true, only: :test},
      {:loopex_llm_reqllm, in_umbrella: true, only: :test},
      {:loopex_executor_local, in_umbrella: true, only: :test}
    ]
  end
end

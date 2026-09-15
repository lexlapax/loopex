defmodule Loopex.Telemetry.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_telemetry,
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

  # Concept: the edge that carries telemetry events to a runtime's diagnostics
  # plane, and the only place a Loopex-attached handler lives.
  #
  # Technical depth: it depends inward on core and outward on `:telemetry`
  # alone. Reporters and exporters live here or in a host adapter and never in
  # core, protocol or the app-server.
  defp deps do
    [{:loopex, in_umbrella: true}, {:telemetry, "~> 1.3"}]
  end
end

defmodule LoopexProtocol.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_protocol,
      loopex_role: :contract,
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

  # Concept: the contract application carries no dependency at all, so an
  # out-of-repository extension author compiles against it without pulling the
  # runtime in. ADR 0001 fixes this; `mix loopex.deps_budget` enforces it.
  defp deps do
    []
  end
end

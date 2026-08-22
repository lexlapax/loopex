defmodule Loopex.Store.Local.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_store_local,
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

  # Concept: the local Store is an outward implementation of the core port.
  #
  # Technical depth: it depends only on core. Its file format uses OTP and the
  # Elixir standard library; M1 authorizes no database or storage dependency.
  defp deps do
    [{:loopex, in_umbrella: true}]
  end
end

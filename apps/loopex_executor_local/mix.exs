defmodule Loopex.Executor.Local.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_executor_local,
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

  def application, do: [extra_applications: []]

  # Concept: the trusted-local hand depends inward on the executor contract and
  # owns every OS and workspace detail at this edge.
  #
  # Technical depth: no concrete sibling adapter or external package is needed;
  # OS process control, monitoring, and the retained receipt ledger use OTP and
  # the standard library.
  defp deps, do: [{:loopex, in_umbrella: true}]
end

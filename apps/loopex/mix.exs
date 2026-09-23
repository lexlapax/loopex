defmodule Loopex.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex,
      loopex_role: :core,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # Support modules are loaded by the cases that need them; without this the
      # test loader warns that they match no filter, and the suite runs with
      # warnings as errors.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end

  # Concept: the contract application, and the one external dependency the
  # vision admits by name.
  #
  # Technical depth: accepted ADR 0030 supersedes ADR 0001's empty-dependency
  # clause for this application exactly far enough to admit `:telemetry`, the
  # single dispatcher the dependency doctrine names, and nothing else. There is
  # still no development, test, formatter, analysis or documentation dependency
  # here, and providers, stores, executors and transports live in adapter
  # applications that depend inward on this one.
  defp deps do
    [{:loopex_protocol, in_umbrella: true}, {:telemetry, "~> 1.3"}]
  end
end

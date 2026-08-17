defmodule Loopex.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex,
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

  # Concept: the runtime's only dependency is the contract application. Core is
  # stdlib and OTP otherwise; providers, stores, executors, and transports live
  # in adapter applications that depend inward on this one.
  defp deps do
    [{:loopex_protocol, in_umbrella: true}]
  end
end

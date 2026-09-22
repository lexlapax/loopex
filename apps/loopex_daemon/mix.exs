defmodule LoopexDaemon.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_daemon,
      loopex_role: :host,
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

  def application, do: [extra_applications: [:crypto]]

  # Concept: the daemon is the host role: a long-lived owner of the reference
  # composition that the reference CLI starts. It owns neither a second loop
  # nor a concrete edge.
  #
  # Technical depth: the protocol dependency names the generation it serves,
  # while the composition remains the single production application that names
  # Store, Model and Executor implementations.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_protocol, in_umbrella: true},
      {:loopex_composition, in_umbrella: true}
    ]
  end
end

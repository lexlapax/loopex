defmodule LoopexCli.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_cli,
      loopex_role: :client,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # The demonstration stack is a support module rather than a test file, and
      # without this the test loader warns that it matches no filter -- a warning
      # on every run of a checkpoint that is required to carry none.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      # The command an operator types is `loopex`. Without an explicit name the
      # escript takes the application's, and the documentation would be
      # describing a command that does not exist under that name.
      escript: [main_module: LoopexCli, name: :loopex],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: []]

  # Concept: the operator command is a client and a peer surface.
  #
  # Technical depth: it owns no loop, no durable session truth, no cursor truth,
  # no Store access, and no authority decision. It depends on the runtime for the
  # public facade and on exactly one composition for wiring, which is the whole
  # of what a client may declare in production.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_composition, in_umbrella: true}
    ]
  end
end

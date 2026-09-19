defmodule Loopex.AppServer.MixProject do
  use Mix.Project

  @version File.read!(Path.join([__DIR__, "..", "..", "VERSION"])) |> String.trim()

  def project do
    [
      app: :loopex_app_server,
      loopex_role: :client,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      # The launch configuration a workflow case starts its server process with
      # is required by that case, not run as a selector. Current Mix warns on an
      # unclassified .exs file; no *_test.exs is ignored here.
      test_ignore_filters: [
        "test/support/fixture_server.exs"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
  end

  # Concept: the foreground server is a client of the runtime, not a second
  # runtime.
  #
  # Technical depth: it depends inward on core for the session contract, on the
  # contract application for the wire schema it speaks, and on a composition for
  # the placement it is launched with. That contract edge is declared rather
  # than reached through core, so what it speaks is visible here. It adds no
  # external production dependency at all.
  defp deps do
    [
      {:loopex, in_umbrella: true},
      {:loopex_protocol, in_umbrella: true},
      {:loopex_composition, in_umbrella: true}
    ]
  end
end

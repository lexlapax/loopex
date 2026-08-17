defmodule Loopex.Umbrella.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      apps_path: "apps",
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Concept: the umbrella root coordinates applications and owns no dependency
  # of its own, so the dependency budget has a single meaning per application.
  defp deps do
    []
  end
end

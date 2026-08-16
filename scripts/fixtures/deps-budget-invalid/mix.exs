# Deliberately invalid fixture: the core application may declare no dependency.
# The dependency-budget command must reject this, and the after-edit hook must
# be path-aware enough to run that command against it.
defmodule LoopexInvalidFixture.MixProject do
  use Mix.Project

  def project do
    [app: :loopex, version: "0.0.0", deps: deps()]
  end

  defp deps do
    [{:req_llm, "~> 1.0"}]
  end
end

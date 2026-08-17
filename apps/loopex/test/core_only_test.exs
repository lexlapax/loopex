defmodule Mix.Tasks.Loopex.CoreOnlyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Loopex.CoreOnly

  @moduletag timeout: 180_000

  test "core starts with no adapter application resolved or started" do
    # The lane is a separate VM running core's own project. Asserting against the
    # ambient VM would be the anti-pattern the gate names: at an umbrella root
    # every compiled child is on the load path, so the assertion would fail the
    # moment any adapter exists while proving nothing about core's own closure.
    assert {:ok, lane} = CoreOnly.isolated_lane(LoopexTest.Repo.root())

    assert "loopex" in lane.started, "the lane did not start core, so it proved nothing"
    assert Enum.reject(lane.loaded, &CoreOnly.adapter?/1) == lane.loaded
    assert Enum.reject(lane.started, &CoreOnly.adapter?/1) == lane.started
  end

  test "per-runtime state is not read from application environment" do
    assert CoreOnly.check(LoopexTest.Repo.root()) == :ok
  end

  test "an adapter name is recognised and the runtime and contract are not" do
    assert CoreOnly.adapter?(:loopex_llm_reqllm)
    assert CoreOnly.adapter?("loopex_anything")
    refute CoreOnly.adapter?(:loopex)
    refute CoreOnly.adapter?(:loopex_protocol)
    refute CoreOnly.adapter?(:elixir)
  end
end

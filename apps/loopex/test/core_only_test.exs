defmodule Mix.Tasks.Loopex.CoreOnlyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.CoreOnly

  test "core starts with no adapter application resolved or started" do
    assert CoreOnly.adapter_applications() == []
    assert Application.spec(:loopex_llm_reqllm) == nil
  end

  test "per-runtime state is not read from application environment" do
    assert CoreOnly.check(LoopexTest.Repo.root()) == :ok
  end
end

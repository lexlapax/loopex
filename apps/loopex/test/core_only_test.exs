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

  test "a core source reading application environment is rejected" do
    # Without this the assertion above is unproven rather than vacuous: delete the
    # AST walk and `check/1` still returns :ok on a clean tree, so a successful
    # no-op is indistinguishable from a working check. The gate says exactly that
    # about the other Mix obligations and locks a rejection case for each; this one
    # had none.
    root = Path.join(System.tmp_dir!(), "core-only-#{System.unique_integer([:positive])}")
    lib = Path.join(root, "apps/loopex/lib")
    File.mkdir_p!(lib)
    on_exit(fn -> File.rm_rf(root) end)

    for reader <- [:get_env, :fetch_env, :fetch_env!] do
      source =
        "defmodule Offender do\n  def runtime, do: Application.#{reader}(:loopex, :x)\nend\n"

      File.write!(Path.join(lib, "offender.ex"), source)

      assert {:error, reasons} = CoreOnly.check(root),
             "Application.#{reader} in core must be rejected"

      assert Enum.any?(reasons, &String.contains?(&1, "Application.#{reader}")),
             "the reason must name the reader it found: #{inspect(reasons)}"

      assert Enum.any?(reasons, &String.contains?(&1, "offender.ex:2")),
             "the reason must name the file and line: #{inspect(reasons)}"
    end

    # The same tree without the read produces no environment reason, so the
    # rejection is about the call and not about the fixture being present at all.
    #
    # Concept: assert on the property this case covers, not on the whole check.
    #
    # Technical depth: `check/1` evaluates both properties, and the isolated lane
    # cannot run in a fixture root that has no Mix project -- so this asserts on
    # the environment reasons rather than on :ok. Asserting :ok here would make
    # the case fail for a reason that has nothing to do with what it covers.
    File.write!(lib <> "/offender.ex", "defmodule Offender do\n  def runtime, do: :caller\nend\n")

    assert {:error, remaining} = CoreOnly.check(root)

    refute Enum.any?(remaining, &String.contains?(&1, "Application.")),
           "a source with no environment read must produce no environment reason: " <>
             inspect(remaining)
  end

  test "an adapter name is recognised and the runtime and contract are not" do
    assert CoreOnly.adapter?(:loopex_llm_reqllm)
    assert CoreOnly.adapter?("loopex_anything")
    refute CoreOnly.adapter?(:loopex)
    refute CoreOnly.adapter?(:loopex_protocol)
    refute CoreOnly.adapter?(:elixir)
  end
end

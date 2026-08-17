defmodule Mix.Tasks.Loopex.FormatScopeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.FormatScope

  setup do
    dir = Path.join(System.tmp_dir!(), "format-scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, "apps", "example", "lib"]))
    File.write!(Path.join([dir, "apps", "example", "lib", "example.ex"]), "defmodule E do\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the repository formatter scope resolves to application sources" do
    assert {:ok, count} = FormatScope.check(LoopexTest.Repo.root())
    assert count > 0
  end

  test "a root-only formatter configuration is rejected", %{dir: dir} do
    # Root-only inputs: an umbrella root formats nothing of its own, so
    # `mix format --check-formatted` would pass having examined no application.
    File.write!(Path.join(dir, ".formatter.exs"), ~s([inputs: ["{mix,.formatter}.exs"]]\n))

    assert {:error, reason} = FormatScope.check(dir)
    assert reason =~ "no file under apps/"
  end

  test "an apps glob that resolves is accepted", %{dir: dir} do
    File.write!(
      Path.join(dir, ".formatter.exs"),
      ~s([inputs: ["apps/*/{lib,test}/**/*.{ex,exs}"]]\n)
    )

    assert {:ok, 1} = FormatScope.check(dir)
  end
end

defmodule Mix.Tasks.Loopex.DocsCheckTest do
  @moduledoc """
  ## Concept

  Proves the compiled-documentation check rejects the shapes it exists to reject,
  and reports what it did not cover separated by reason.

  ## Technical depth

  Outcome 10 had no test. Its whole evidence was the exit status of a command plus
  a count the plan deliberately does not freeze, so a regression that made the
  check inspect nothing would still have exited 0 and still have printed a
  plausible line. The gate says the same thing about the other Mix obligations --
  "either task could be a successful no-op" -- and locks a rejection case for
  each; this one had none.

  Fixtures are compiled to beams in a temporary build path and read back through
  the same `Code.fetch_docs/1` path the task uses, rather than by calling a
  private classifier. A test that inspected source text would pass while the task
  read compiled docs and saw something else.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.DocsCheck

  setup do
    build = Path.join(System.tmp_dir!(), "docs-check-#{System.unique_integer([:positive])}")
    ebin = Path.join(build, "lib/fixture/ebin")
    File.mkdir_p!(ebin)
    on_exit(fn -> File.rm_rf(build) end)
    {:ok, build: build, ebin: ebin}
  end

  # Compiles one module into the fixture ebin so the task finds it by wildcard.
  #
  # Technical depth: the Docs chunk is opt-in here. Without it every fixture beam
  # came back `:chunk_not_found`, and the two rejection cases passed on THAT error
  # rather than on the ordering they name -- the message carries the module name,
  # so "the reason names the module" was satisfied by a beam the task could not
  # read at all. The chunk is written explicitly, and the accepted case below is
  # what proves it is really there.
  defp compile!(ebin, source) do
    previous = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    try do
      [{module, binary} | _] = Code.compile_string(source)
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      module
    after
      Code.put_compiler_option(:docs, previous)
    end
  end

  test "a module documenting depth before purpose is rejected", %{build: build, ebin: ebin} do
    compile!(ebin, """
    defmodule DocsFixtureInverted do
      @moduledoc \"\"\"
      ## Technical depth

      Depth first.

      ## Concept

      Purpose second.
      \"\"\"
    end
    """)

    assert {:error, reasons} = DocsCheck.check(build, ["fixture"])

    assert Enum.any?(reasons, &String.contains?(&1, "DocsFixtureInverted")),
           "the reason must name the offending module: #{inspect(reasons)}"
  end

  test "a module missing the depth section is rejected", %{build: build, ebin: ebin} do
    compile!(ebin, """
    defmodule DocsFixtureHalf do
      @moduledoc \"\"\"
      ## Concept

      Purpose only.
      \"\"\"
    end
    """)

    assert {:error, _reasons} = DocsCheck.check(build, ["fixture"])
  end

  test "a correctly documented module is accepted and counted as covered", %{
    build: build,
    ebin: ebin
  } do
    compile!(ebin, """
    defmodule DocsFixtureOrdered do
      @moduledoc \"\"\"
      ## Concept

      Purpose first.

      ## Technical depth

      Depth second.
      \"\"\"
    end
    """)

    assert {:ok, result} = DocsCheck.check(build, ["fixture"])
    assert result.covered >= 1, "the ordered module must count as covered"
  end

  test "what was not covered is reported separated by reason", %{build: build, ebin: ebin} do
    # One tally carried three different facts and the command called all of them
    # "explicitly undocumented", so an author declaring an entry out of scope, an
    # author who forgot, and a macro injecting child_spec/1 were the same number.
    # A public function losing its @doc read as a deliberate declaration.
    compile!(ebin, """
    defmodule DocsFixtureHidden do
      @moduledoc false
    end
    """)

    assert {:ok, result} = DocsCheck.check(build, ["fixture"])
    assert result.hidden.hidden == 1, "a declared @moduledoc false is one declared exclusion"
    assert result.hidden.none == 0, "nothing here was silently undocumented"
  end

  test "an application with no compiled beams is unavailable evidence, not a pass", %{
    build: build
  } do
    # Fails closed: a wildcard that matches nothing must not read as "everything
    # covered", which is the shape a successful no-op takes.
    assert {:error, reasons} = DocsCheck.check(build, ["absent"])
    assert Enum.any?(reasons, &String.contains?(&1, "unavailable"))
  end
end

# Concept: exercise the exact standalone check without starting a VM per vector.
# Technical depth: only its module form is compiled here. A separate case runs
# the actual CLI; no candidate production module is loaded or evaluated by it.
checker_path = Path.expand("../../../scripts/m0-child-env-check.exs", __DIR__)
{:__block__, _, [checker_module, _cli]} = Code.string_to_quoted!(File.read!(checker_path))
Code.compile_quoted(checker_module, checker_path)

defmodule Loopex.M0ChildEnvironmentCheckTest do
  use ExUnit.Case, async: false
  alias Loopex.M0ChildEnvironmentCheck, as: Checker

  @root Path.expand("../../..", __DIR__)
  @launcher "apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/provider_launcher.ex"
  @fixture "apps/loopex_llm_reqllm/test/support/provider_build_fixture.exs"
  @checker Path.join(@root, "scripts/m0-child-env-check.exs")
  @runner Path.join(@root, "scripts/check-m0-gate.sh")

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-m0-child-env-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-q"])

    sources = Map.new([@launcher, @fixture], &{&1, File.read!(Path.join(@root, &1))})
    for {path, source} <- sources, do: put!(root, path, source)
    git!(root, ["add", "--", @launcher, @fixture])

    [assignment] =
      @runner
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "path_mutation="))

    {matcher, 0} =
      System.cmd("/bin/bash", ["-c", assignment <> "\nprintf '%s' \"$path_mutation\""])

    %{root: root, sources: sources, matcher: matcher}
  end

  test "the four reviewed occurrences pass through the real Git matcher and checker", context do
    matches = matches!(context)
    assert length(:binary.matches(matches, <<0>>)) == 8
    assert Checker.check(context.root, matches) == {:ok, 4}

    # The constructor locations are derived, not fixed line numbers.
    for {path, source} <- context.sources, do: put!(context.root, path, "\n\n" <> source)
    assert Checker.check(context.root, matches!(context)) == {:ok, 4}
  end

  test "every changed constructor is refused in its own boundary", context do
    changes = [
      {@launcher, ~s(       "PATH=/usr/bin:/bin",), ~s(       "PATH=/usr/bin",), "vector/5"},
      {@launcher, "env -i PATH=/usr/bin:/bin LANG=C", "env -i PATH=/usr/bin LANG=C",
       "guard_program/0"},
      {@fixture, ~s(otp_bin, "/usr/bin", "/bin"), ~s(otp_bin, "/bin", "/usr/bin"), "build!/1"},
      {@fixture, ~s(%{"PATH" => "/usr/bin:/bin",), ~s(%{"PATH" => "/usr/bin",), "clean_source!/0"}
    ]

    for {path, before, after_text, boundary} <- changes do
      change!(context, path, before, after_text)
      assert {:error, reason} = Checker.check(context.root, matches!(context))
      assert reason =~ path and reason =~ boundary
      restore!(context)
    end
  end

  test "construction use and intervening reassignment are checked independently", context do
    changes = [
      {"env: Map.to_list(environment)", "env: []", "build!/1"},
      {"    {output, status} =\n      System.cmd(",
       "    environment = %{}\n    {output, status} =\n      System.cmd(", "build!/1"},
      {"env: environment\n      )", "env: []\n      )", "clean_source!/0"},
      {~s(["rev-parse", "HEAD"], cd: @source_root, env: environment),
       ~s(["rev-parse", "HEAD"], cd: @source_root, env: []), "clean_source!/0"}
    ]

    for {before, after_text, boundary} <- changes do
      change!(context, @fixture, before, after_text)
      assert {:error, reason} = Checker.check(context.root, matches!(context))
      assert reason =~ boundary
      restore!(context)
    end
  end

  test "a constructor moved to another function or module is refused", context do
    for {path, before, after_text} <- [
          {@launcher, "def vector(", "def another_vector("},
          {@launcher, "defp guard_program do", "defp another_guard do"},
          {@fixture, "defp build!(build) do", "defp another_build!(build) do"},
          {@fixture, "defp clean_source! do", "defp another_source! do"},
          {@launcher, "defmodule Loopex.LLM.ReqLLM.ProviderLauncher do",
           "defmodule OtherLauncher do"}
        ] do
      change!(context, path, before, after_text)
      assert {:error, _} = Checker.check(context.root, matches!(context))
      restore!(context)
    end
  end

  test "duplicate functions and extra occurrences in registered files are refused", context do
    for {path, insertion} <- [
          {@launcher, "  def vector(a,b,c,d,e), do: {a,b,c,d,e}\n"},
          {@launcher, "  defp guard_program, do: :duplicate\n"},
          {@fixture, "  defp build!(root), do: root\n"},
          {@fixture, "  defp clean_source!, do: :duplicate\n"},
          {@launcher, "  @extra \"PATH=/unregistered\"\n"},
          {@fixture, "  @extra \"PATH=/unregistered\"\n"}
        ] do
      source = Map.fetch!(context.sources, path)
      put!(context.root, path, String.replace_suffix(source, "end\n", insertion <> "end\n"))
      assert {:error, _} = Checker.check(context.root, matches!(context))
      restore!(context)
    end
  end

  test "an extra binding on an admitted line is not subtracted", context do
    change!(
      context,
      @launcher,
      "env -i PATH=/usr/bin:/bin LANG=C",
      "env -i PATH=/usr/bin:/bin PATH=/extra LANG=C"
    )

    assert {:error, reason} = Checker.check(context.root, matches!(context))
    assert reason =~ "guard_program/0"
  end

  test "the legacy binding forms remain refused outside the registered occurrences", context do
    vectors = [
      "PATH=/owned",
      "export PATH=/owned",
      "export \"PATH\"=/owned",
      "unset PATH",
      "printf -v PATH value",
      "PATH[0]=value",
      "declare PATH",
      "local PATH",
      "readonly PATH",
      "typeset PATH",
      "read PATH",
      "mapfile -t PATH",
      "readarray PATH",
      "for PATH in owned; do :; done",
      "select PATH in owned; do :; done"
    ]

    for vector <- vectors do
      # Input is data for the matcher; none of these shell fragments is executed.
      put!(context.root, "extra.md", vector <> "\n")
      git!(context.root, ["add", "--", "extra.md"])
      assert {:error, reason} = Checker.check(context.root, matches!(context)), vector
      assert reason =~ "extra.md" and reason =~ "unregistered", vector
    end
  end

  test "a matching copy at another path is not a registered boundary", context do
    put!(context.root, "copy.ex", Map.fetch!(context.sources, @launcher))
    git!(context.root, ["add", "--", "copy.ex"])
    assert {:error, reason} = Checker.check(context.root, matches!(context))
    assert reason =~ "copy.ex"
  end

  test "malformed and duplicated matcher frames are refused", context do
    valid = matches!(context)
    assert {:error, "duplicate matcher record"} = Checker.check(context.root, valid <> valid)

    for invalid <- [
          "path",
          "path\0",
          "path\0bad\0text\n",
          "path\00\0text\n",
          "path\01\0text",
          "\01\0text\n"
        ] do
      assert {:error, "malformed Git matcher record"} = Checker.check(context.root, invalid)
    end
  end

  test "mismatched line evidence and unavailable source are refused", context do
    original = matches!(context)

    assert {:error, _} =
             Checker.check(
               context.root,
               String.replace(original, "       \"PATH=", "      \"PATH=")
             )

    File.rm!(Path.join(context.root, @launcher))
    assert {:error, reason} = Checker.check(context.root, original)
    assert reason =~ "readable regular source"
    restore!(context)
    File.rm!(Path.join(context.root, @launcher))
    File.ln_s!(Path.join(@root, @launcher), Path.join(context.root, @launcher))
    assert {:error, reason} = Checker.check(context.root, original)
    assert reason =~ "readable regular source"
  end

  test "malformed registered Elixir is unavailable evidence and an empty scan is clean",
       context do
    original = matches!(context)

    put!(
      context.root,
      @launcher,
      Map.fetch!(context.sources, @launcher) <> "defmodule Broken do\n"
    )

    assert {:error, reason} = Checker.check(context.root, original)
    assert reason =~ "inspection unavailable"
    assert Checker.check(context.root, "") == {:ok, 0}
  end

  test "the standalone CLI refuses unregistered matches and missing input", context do
    input = Path.join(context.root, "matches.bin")
    File.write!(input, matches!(context))
    elixir = Path.expand("../../bin/elixir", List.to_string(:code.lib_dir(:elixir)))

    assert {output, 0} =
             System.cmd(elixir, [@checker, context.root, input], stderr_to_stdout: true)

    assert output == "M0 child-environment occurrences OK: 4\n"

    # A diagnostic with exit zero would let the actual shell runner continue.
    # Generate the refusal through real Git framing, not an invented error term.
    put!(context.root, "extra.md", "PATH=/unregistered\n")
    git!(context.root, ["add", "--", "extra.md"])
    File.write!(input, matches!(context))

    assert {output, 1} =
             System.cmd(elixir, [@checker, context.root, input], stderr_to_stdout: true)

    assert output =~ "extra.md" and output =~ "unregistered search-path construction"

    assert {output, 2} =
             System.cmd(elixir, [@checker, context.root, input <> ".absent"],
               stderr_to_stdout: true
             )

    assert output =~ "matcher input unavailable"
  end

  defp matches!(context) do
    case System.cmd("git", ["-C", context.root, "grep", "-n", "-zE", context.matcher, "--", "."],
           stderr_to_stdout: true
         ) do
      {matches, status} when status in [0, 1] -> matches
      {output, status} -> flunk("Git matcher unavailable (#{status}): #{output}")
    end
  end

  defp change!(context, path, before, after_text) do
    original = Map.fetch!(context.sources, path)
    changed = String.replace(original, before, after_text, global: false)
    refute changed == original, "fixture did not change #{path}"
    put!(context.root, path, changed)
  end

  defp restore!(context) do
    for {path, source} <- context.sources, do: put!(context.root, path, source)
  end

  defp put!(root, path, bytes) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
  end

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end

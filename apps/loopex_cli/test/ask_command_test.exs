defmodule LoopexCli.AskCommandTest do
  @moduledoc """
  ## Concept

  Proves that the built command admits both standalone spellings in a separate
  process and exits with their fixed diagnostic bytes.

  ## Technical depth

  The test builds a fresh escript from this test run's compiled beams into an
  owned temporary path. Its shell capture keeps stdout and stderr separate;
  it never trusts the possibly older command file in the checkout.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  test "fresh command refuses invalid ask and -p without stdout or a state root" do
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    command = build_command(root)
    state_root = Path.join(root, "unused-state-root")

    for spelling <- ["ask", "-p"] do
      {status, stdout, stderr} =
        capture(command, [spelling, "--output", "wrong", "fixture"], root, state_root)

      assert status == 1
      assert stdout == ""
      assert stderr == "loopex: invalid_output\n"
      refute File.exists?(state_root)
    end

    {status, stdout, stderr} = capture(command, [], root, state_root)
    assert status == 1
    assert stdout == ""
    assert String.starts_with?(stderr, "loopex: choose one command:")
    refute File.exists?(state_root)
  end

  defp temporary_directory do
    root =
      Path.join(System.tmp_dir!(), "loopex-ask-command-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    root
  end

  defp build_command(root) do
    {:ok, _} = Application.ensure_all_started(:mix)
    command = Path.join(root, "loopex")

    build = fn ->
      assert Path.expand(Mix.Project.compile_path()) ==
               Path.expand(Application.app_dir(:loopex_cli, "ebin"))

      original = Mix.Project.config()[:escript]
      Mix.ProjectStack.merge_config(escript: Keyword.put(original, :path, command))

      try do
        Mix.Tasks.Escript.Build.run(["--no-compile", "--no-deps-check"])
      after
        Mix.ProjectStack.merge_config(escript: original)
      end
    end

    if Mix.Project.get() == LoopexCli.MixProject do
      build.()
    else
      Mix.Project.in_project(:loopex_cli, Path.expand("..", __DIR__), fn _ -> build.() end)
    end

    assert File.regular?(command)
    assert Bitwise.band(File.stat!(command).mode, 0o111) != 0
    {:ok, sections} = :escript.extract(String.to_charlist(command), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    for module <- [LoopexCli, LoopexCli.Ask] do
      name = Atom.to_string(module) <> ".beam"

      embedded =
        Enum.find_value(entries, fn {path, bytes} ->
          if Path.basename(List.to_string(path)) == name, do: bytes
        end)

      assert {:ok, {^module, embedded_hash}} = :beam_lib.md5(embedded)
      assert {:ok, {^module, current_hash}} = :beam_lib.md5(:code.which(module))
      assert embedded_hash == current_hash
    end

    command
  end

  defp capture(command, argv, root, state_root) do
    number = System.unique_integer([:positive])
    stdout_path = Path.join(root, "stdout-#{number}")
    stderr_path = Path.join(root, "stderr-#{number}")

    script =
      "command=$1; stdout=$2; stderr=$3; shift 3; exec \"$command\" \"$@\" >\"$stdout\" 2>\"$stderr\""

    {shell_output, status} =
      System.cmd(
        "/bin/sh",
        ["-c", script, "capture", command, stdout_path, stderr_path] ++ argv,
        cd: root,
        env: [
          {"LOOPEX_HOME", state_root},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"OPENAI_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"OPEN_ROUTER_API_KEY", nil},
          {"ERL_LIBS", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_ZFLAGS", nil}
        ]
      )

    assert shell_output == ""
    {status, File.read!(stdout_path), File.read!(stderr_path)}
  end
end

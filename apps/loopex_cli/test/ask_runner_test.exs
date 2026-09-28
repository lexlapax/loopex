defmodule LoopexCli.AskRunnerTest do
  use ExUnit.Case, async: true

  alias LoopexCli.Ask

  test "both command spellings admit the same exact prompt before application startup" do
    for command <- ["ask", "-p"] do
      assert {:ok, %{options: options, cwd: "/verified", prompt: "first  second"}} =
               Ask.prepare(
                 [command, "--policy=allow-all", "first", "", "second"],
                 cwd: fn -> {:ok, "/current"} end,
                 resolve_path: fn "/current" -> {:ok, "/verified"} end,
                 directory_identity: fn "/verified" -> {:ok, {1, 2}} end
               )

      assert options.profile == :ephemeral
      refute Map.has_key?(options, :words)
    end
  end

  test "explicit cwd does not consult process cwd; prompt words do not read stdin" do
    assert {:ok, %{cwd: "/verified", prompt: "hello"}} =
             Ask.prepare(
               ["ask", "--policy", "allow-all", "--cwd", "/selected", "hello"],
               cwd: fn -> flunk("must not read cwd") end,
               input: :unreadable,
               resolve_path: fn "/selected" -> {:ok, "/verified"} end,
               directory_identity: fn "/verified" -> {:ok, {1, 2}} end
             )
  end

  test "structural and value refusals precede workspace and stdin" do
    assert Ask.prepare(
             ["ask", "--output", "wrong", "--policy", "allow-all"],
             cwd: fn -> flunk("must not read cwd") end,
             input: :unreadable
           ) == diagnostic(:invalid_output)

    assert Ask.prepare(
             ["-p", "--policy", "allow-all", "--not-a-flag", "secret"],
             cwd: fn -> flunk("must not read cwd") end,
             input: :unreadable
           ) == diagnostic(:invalid_arguments)
  end

  test "workspace failure precedes prompt and startup" do
    assert Ask.prepare(
             ["ask", "--policy", "allow-all"],
             cwd: fn -> {:error, :enoent} end,
             input: :unreadable
           ) == diagnostic(:workspace_unusable)

    assert Ask.prepare(
             ["ask", "--policy", "allow-all", "--cwd", "/not-directory", "hello"],
             resolve_path: fn path -> {:ok, path} end,
             directory_identity: fn _ -> {:error, :workspace_root_not_directory} end
           ) == diagnostic(:workspace_unusable)
  end

  test "stdin bytes are preserved and prompt refusal is fixed" do
    {:ok, input} = StringIO.open("  exact\n")

    assert {:ok, %{prompt: "  exact\n"}} =
             Ask.prepare(["ask", "--policy", "allow-all"], input: input)

    {:ok, empty} = StringIO.open("")

    assert Ask.prepare(["ask", "--policy", "allow-all"], input: empty) ==
             diagnostic(:invalid_prompt_empty)
  end

  test "durable startup happens after admission and its failure has no caller bytes" do
    assert {:ok, admitted} =
             Ask.prepare([
               "ask",
               "--state-root",
               "/tmp/ask-root",
               "--policy",
               "allow-all",
               "hello"
             ])

    assert Ask.execute_durable(admitted,
             start_application: fn -> {:error, {:loopex_cli, {:secret, "never print"}}} end,
             durable_run: fn _, _, _ -> flunk("runtime must not start") end
           ) == diagnostic(:application_start_failed)

    answer = %{status: 0, stdout: "answer\n", stderr: ""}

    assert Ask.execute_durable(admitted,
             start_application: fn -> {:ok, []} end,
             durable_run: fn options, cwd, prompt ->
               assert options.profile == :durable
               assert cwd == admitted.cwd
               assert prompt == "hello"
               answer
             end
           ) == answer
  end

  test "unexpected durable return is contained without inspecting its value" do
    admitted = %{
      options: %{profile: :durable},
      cwd: "/workspace",
      prompt: "hello"
    }

    assert Ask.execute_durable(admitted,
             start_application: fn -> {:ok, []} end,
             durable_run: fn _, _, _ -> {:secret, "never print"} end
           ) == diagnostic(:command_failed)
  end

  defp diagnostic(code), do: LoopexCli.AskResult.diagnostic(code)
end

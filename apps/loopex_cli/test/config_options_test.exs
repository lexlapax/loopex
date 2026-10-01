defmodule LoopexCli.ConfigOptionsTest do
  use ExUnit.Case, async: true
  alias LoopexCli.ConfigOptions
  @uint64 18_446_744_073_709_551_615

  test "three command forms require config and retain only explicit overrides" do
    for {prefix, command, suffix} <- [
          {["chat"], :chat, []},
          {["config", "validate"], :validate, []},
          {["config", "show"], :show, ["--effective"]}
        ] do
      assert ConfigOptions.parse(prefix ++ ["--config", "profile.json"] ++ suffix) ==
               {:ok, %{command: command, config: "profile.json", resume: nil, overrides: %{}}}

      assert ConfigOptions.parse(prefix ++ suffix) == {:error, {:missing_flag, "/flags/config"}}
    end

    assert ConfigOptions.parse(["config", "show", "--config=p.json"]) ==
             {:error, {:missing_flag, "/flags/effective"}}
  end

  test "all documented nontrace overrides admit both value forms" do
    flags = [
      {"workspace", "work", "work"},
      {"state-root", "state", "state"},
      {"model", "openai:fixture", "openai:fixture"},
      {"reasoning", "low", "low"},
      {"compaction-model", "anthropic:fixture", "anthropic:fixture"},
      {"max-steps", "8", 8},
      {"deadline-ms", "1000", 1000},
      {"token-budget", "9999", 9999},
      {"max-tokens", "4096", 4096},
      {"context-token-budget", "8192", 8192},
      {"system-class-tokens", "1000", 1000},
      {"cleanup-grace-ms", "5000", 5000},
      {"system-prompt-file", "base.txt", "base.txt"},
      {"append-system-prompt-file", "append.txt", "append.txt"},
      {"tools", "read-only", "read-only"},
      {"policy", "refuse-all", "refuse-all"},
      {"output", "text", "text"}
    ]

    for prefix <- [["chat"], ["config", "validate"], ["config", "show"]],
        {name, raw, expected} <- flags do
      effective = if prefix == ["config", "show"], do: ["--effective"], else: []

      for authored <- [["--#{name}", raw], ["--#{name}=#{raw}"]] do
        assert {:ok, parsed} =
                 ConfigOptions.parse(prefix ++ ["--config=p.json"] ++ effective ++ authored)

        assert parsed.overrides == %{name => expected}
      end
    end
  end

  test "arrays preserve authored order and no-helpers carries an explicit narrowing" do
    assert {:ok, parsed} =
             ConfigOptions.parse([
               "chat",
               "--config=p.json",
               "--skill-dir=first",
               "--skill-dir",
               "second",
               "--no-helpers"
             ])

    assert parsed.overrides == %{"skill-dir" => ["first", "second"], "no-helpers" => true}
    assert {:ok, parsed} = ConfigOptions.parse(["chat", "--config=p.json", "--resume=session-id"])
    assert parsed.resume == "session-id"
  end

  test "scalar duplicates and mutually exclusive trace booleans refuse" do
    for flags <- [
          ["--config=a", "--config=b"],
          ["--model=openai:a", "--model=openai:b"],
          ["--no-helpers", "--no-helpers"],
          ["--trace", "--no-trace"],
          ["--no-trace", "--trace"],
          ["--trace", "--trace"]
        ] do
      assert {:error, {:duplicate_flag, _}} =
               ConfigOptions.parse(["chat", "--config=p.json"] ++ flags)
    end

    assert ConfigOptions.parse([
             "config",
             "show",
             "--config=p.json",
             "--effective",
             "--effective"
           ]) == {:error, {:duplicate_flag, "/flags/effective"}}
  end

  test "inspection refuses every trace flag and resume without effects" do
    for prefix <- [["config", "validate"], ["config", "show"]],
        flag <- [
          "--trace",
          "--no-trace",
          "--trace-level=calls",
          "--trace-module=Loopex.*",
          "--trace-max-entry-bytes=1",
          "--trace-max-entries-per-second=1",
          "--trace-max-queue-entries=1",
          "--resume=session"
        ] do
      assert ConfigOptions.parse(prefix ++ ["--config=p.json", flag]) ==
               {:error, {:invalid_arguments, ""}}
    end
  end

  test "chat trace options use admitted selectors and can only lower ceilings" do
    argv = [
      "chat",
      "--config=p.json",
      "--no-trace",
      "--trace-level=arguments",
      "--trace-module=Loopex.*",
      "--trace-module",
      "Loopex.Runtime",
      "--trace-max-entry-bytes=4096",
      "--trace-max-entries-per-second=2000",
      "--trace-max-queue-entries=8192"
    ]

    assert {:ok, parsed} = ConfigOptions.parse(argv)
    assert parsed.overrides["trace"] == false
    assert parsed.overrides["trace-module"] == ["Loopex.*", "Loopex.Runtime"]

    for flag <- [
          "--trace-level=all",
          "--trace-module=ReqLLM.*",
          "--trace-max-entry-bytes=4097",
          "--trace-max-entries-per-second=2001",
          "--trace-max-queue-entries=8193"
        ] do
      assert {:error, {:invalid_flag_value, _}} =
               ConfigOptions.parse(["chat", "--config=p.json", flag])
    end
  end

  test "integer flag domains retain exact large spending bounds" do
    for flag <- ~w(max-steps token-budget) do
      assert {:ok, parsed} =
               ConfigOptions.parse(["chat", "--config=p.json", "--#{flag}=#{@uint64 + 1}"])

      assert parsed.overrides[flag] == @uint64 + 1
    end

    for flag <- ~w(deadline-ms context-token-budget system-class-tokens cleanup-grace-ms) do
      assert {:ok, parsed} =
               ConfigOptions.parse(["chat", "--config=p.json", "--#{flag}=#{@uint64}"])

      assert parsed.overrides[flag] == @uint64

      assert ConfigOptions.parse(["chat", "--config=p.json", "--#{flag}=#{@uint64 + 1}"]) ==
               {:error, {:invalid_flag_value, "/flags/#{flag}"}}
    end

    for value <- ~w(0 -1 +1 01 1.0 1e3),
        flag <-
          ~w(max-steps deadline-ms token-budget max-tokens context-token-budget system-class-tokens cleanup-grace-ms) do
      assert ConfigOptions.parse(["chat", "--config=p.json", "--#{flag}=#{value}"]) ==
               {:error, {:invalid_flag_value, "/flags/#{flag}"}}
    end
  end

  test "structural failures precede value failures and never echo authored secrets" do
    for argv <- [
          [],
          ["ask", "--config=p.json"],
          ["config", "unknown"],
          ["chat", "--config=p.json", "prompt"],
          ["chat", "--config=p.json", "--provider=openai"],
          ["chat", "--config=p.json", "--model=bad", "--secret=private-value"],
          ["chat", "--config=p.json", "--workspace"],
          ["chat", "--config=p.json", "--workspace", "--model=openai:x"],
          ["chat", "--config=p.json", "--trace=true"],
          ["chat", "--config=p.json", "--no-helpers=false"],
          ["chat", "--config=p.json", <<255>>],
          ["chat", "--config=p.json", nil],
          ["chat", "--config=p.json" | :tail],
          ["chat", "--config=p.json", "--effective"]
        ] do
      assert ConfigOptions.parse(argv) == {:error, {:invalid_arguments, ""}}
    end
  end

  test "path, resume and array boundaries refuse without substitution or truncation" do
    for value <- ["", "/" <> <<0>>, String.duplicate("x", 4_097)] do
      assert ConfigOptions.parse(["chat", "--config=p.json", "--workspace=#{value}"]) ==
               {:error, {:invalid_flag_value, "/flags/workspace"}}
    end

    assert {:ok, parsed} =
             ConfigOptions.parse([
               "chat",
               "--config=~/profile.json",
               "--workspace=$HOME/work",
               "--resume=" <> String.duplicate("x", 256)
             ])

    assert parsed.config == "~/profile.json"
    assert parsed.overrides["workspace"] == "$HOME/work"

    assert ConfigOptions.parse([
             "chat",
             "--config=p.json",
             "--resume=" <> String.duplicate("x", 257)
           ]) == {:error, {:invalid_flag_value, "/flags/resume"}}

    for {flag, limit} <- [{"skill-dir", 16}, {"trace-module", 64}] do
      value = if flag == "skill-dir", do: "skill", else: "Loopex.*"

      assert {:ok, _} =
               ConfigOptions.parse(
                 ["chat", "--config=p.json"] ++ List.duplicate("--#{flag}=#{value}", limit)
               )

      assert ConfigOptions.parse(
               ["chat", "--config=p.json"] ++ List.duplicate("--#{flag}=#{value}", limit + 1)
             ) == {:error, {:too_many_flag_values, "/flags/#{flag}"}}
    end
  end
end

defmodule LoopexCli.AskOptionsTest do
  use ExUnit.Case, async: true
  alias LoopexCli.AskOptions

  test "ask and -p share one parsed default shape without starting a stack" do
    for command <- ["ask", "-p"] do
      assert {:ok, options} = AskOptions.parse([command, "--policy", "allow-all", "hello"])

      assert options == %{
               profile: :ephemeral,
               output: "text",
               policy: LoopexCli.Policy.AllowAll,
               state_root: nil,
               cwd: nil,
               model: nil,
               tools: :coding,
               skills: [],
               max_steps: nil,
               deadline_ms: nil,
               words: ["hello"]
             }
    end
  end

  test "structural errors precede all value errors and never echo input" do
    cases = [
      ["ask", "--policy", "allow-all", "--secret=x"],
      ["ask", "--output", "wrong", "--model"],
      ["-p", "--policy=allow-all", "--policy=shell-allowlist"],
      ["ask", "--policy", "allow-all", "--policy="],
      ["ask", "--policy", "allow-all", "--tools", "--output=json"],
      ["ask", "--policy", "allow-all", "--tools", ""],
      ["ask", "--policy", "allow-all", "--daemon=x"],
      ["ask", "--policy", "allow-all", "--=x"],
      ["ask", "--" <> <<255>>, "--policy=allow-all"],
      ["ask", "--policy", "allow-all", "--tools", nil],
      ["ask", "--policy", "allow-all" | :tail],
      ["ask", "--policy", "allow-all", "--", :bad],
      :not_argv,
      []
    ]

    for argv <- cases do
      assert AskOptions.parse(argv) == {:error, :invalid_arguments}
    end
  end

  test "flags interleave with words and literal -- ends option parsing" do
    assert {:ok, options} =
             AskOptions.parse([
               "-p",
               "first",
               "--skill-dir",
               "one",
               "--policy=shell-allowlist",
               "-single",
               "--skill-dir=two",
               "--tools=read-only",
               "--output",
               "json",
               "--state-root=/durable",
               "--max-steps",
               "42",
               "--deadline-ms=77",
               "--",
               "--model=positional",
               "",
               "end"
             ])

    assert options == %{
             profile: :durable,
             output: "json",
             policy: LoopexCli.Policy.ShellAllowlist,
             state_root: "/durable",
             cwd: nil,
             model: nil,
             tools: :read_only,
             skills: ["one", "two"],
             max_steps: 42,
             deadline_ms: 77,
             words: ["first", "-single", "--model=positional", "", "end"]
           }
  end

  test "each complete-value domain has a fixed diagnostic for both aliases" do
    bad = <<255>>
    too_long_path = String.duplicate("a", 65_537)
    too_long_model = "p:" <> String.duplicate("a", 511)

    cases = [
      {["--output", "yaml"], :invalid_output},
      {["--state-root", bad], :invalid_state_root},
      {["--state-root", too_long_path], :invalid_state_root},
      {["--state-root", "x\0y"], :invalid_state_root},
      {["--cwd", bad], :invalid_cwd},
      {["--cwd", "x\0y"], :invalid_cwd},
      {["--model", "nocolon"], :invalid_model},
      {["--model", ":id"], :invalid_model},
      {["--model", "provider:"], :invalid_model},
      {["--model", too_long_model], :invalid_model},
      {["--model", bad], :invalid_model},
      {["--tools", "all"], :invalid_tools},
      {["--skill-dir", bad], :invalid_skills},
      {["--skill-dir", "x\0y"], :invalid_skills},
      {["--skill-dir", "same", "--skill-dir=same"], :invalid_skills},
      {[
         "--skill-dir",
         "1",
         "--skill-dir",
         "2",
         "--skill-dir",
         "3",
         "--skill-dir",
         "4",
         "--skill-dir",
         "5"
       ], :invalid_skills},
      {["--max-steps", "0"], :invalid_max_steps},
      {["--max-steps", "01"], :invalid_max_steps},
      {["--max-steps", "+1"], :invalid_max_steps},
      {["--max-steps", "18446744073709551616"], :invalid_max_steps},
      {["--max-steps", bad], :invalid_max_steps},
      {["--deadline-ms", "0"], :invalid_deadline},
      {["--deadline-ms", "1.0"], :invalid_deadline},
      {["--deadline-ms", "1e2"], :invalid_deadline},
      {["--deadline-ms", "18446744073709551616"], :invalid_deadline}
    ]

    for command <- ["ask", "-p"], {flags, reason} <- cases do
      assert AskOptions.parse([command, "--policy", "allow-all" | flags]) == {:error, reason}
    end

    for command <- ["ask", "-p"] do
      assert AskOptions.parse([command, "prompt"]) == {:error, :policy_required}
      assert AskOptions.parse([command, "--policy", "unknown"]) == {:error, :invalid_policy}
    end
  end

  test "all adjacent value failures follow fixed precedence, not argv order" do
    bad = <<255>>

    adjacent = [
      {{["--output", "bad"], :invalid_output}, {["--state-root", bad], :invalid_state_root}},
      {{["--state-root", bad], :invalid_state_root}, {["--cwd", bad], :invalid_cwd}},
      {{["--cwd", bad], :invalid_cwd}, {["--model", "bad"], :invalid_model}},
      {{["--model", "bad"], :invalid_model}, {["--tools", "bad"], :invalid_tools}},
      {{["--tools", "bad"], :invalid_tools}, {["--skill-dir", bad], :invalid_skills}},
      {{["--skill-dir", bad], :invalid_skills}, {["--max-steps", "0"], :invalid_max_steps}},
      {{["--max-steps", "0"], :invalid_max_steps}, {["--deadline-ms", "0"], :invalid_deadline}},
      {{["--deadline-ms", "0"], :invalid_deadline}, {["--policy", "bad"], :invalid_policy}}
    ]

    for {{earlier, reason}, {later, _}} <- adjacent do
      assert AskOptions.parse(["ask" | later ++ earlier]) == {:error, reason}
    end

    assert AskOptions.parse(["ask", "--model=bad", "--tools=bad"]) ==
             {:error, :invalid_model}

    assert AskOptions.parse(["ask", "--output=bad", "--cwd", bad]) ==
             {:error, :invalid_output}

    assert AskOptions.parse(["ask", "--skill-dir", bad, "--output=bad", "--oops=x"]) ==
             {:error, :invalid_arguments}
  end

  test "valid boundaries remain raw and no prompt or provider admission happens here" do
    max = "18446744073709551615"
    path = String.duplicate("a", 65_536)
    model = "future:" <> String.duplicate("x", 505)
    assert byte_size(model) == 512

    assert {:ok, options} =
             AskOptions.parse([
               "ask",
               "--policy=refuse-all",
               "--model",
               model,
               "--cwd",
               path,
               "--skill-dir=one",
               "--skill-dir",
               "two",
               "--skill-dir=three",
               "--skill-dir=four",
               "--tools=none",
               "--max-steps",
               "1",
               "--deadline-ms",
               max,
               "--",
               "",
               <<255>>,
               "--policy=positional"
             ])

    assert options.profile == :ephemeral
    assert options.model == model
    assert options.cwd == path
    assert options.policy == LoopexCli.Policy.RefuseAll
    assert options.tools == :none
    assert options.skills == ~w(one two three four)
    assert options.max_steps == 1
    assert options.deadline_ms == 18_446_744_073_709_551_615
    assert options.words == ["", <<255>>, "--policy=positional"]

    assert {:ok, %{words: [], model: "ollama:name:tag"}} =
             AskOptions.parse(["-p", "--policy=allow-all", "--model=ollama:name:tag"])

    assert {:ok, %{state_root: "/path/that/need/not/exist", profile: :durable}} =
             AskOptions.parse([
               "ask",
               "--policy=allow-all",
               "--state-root=/path/that/need/not/exist"
             ])
  end
end

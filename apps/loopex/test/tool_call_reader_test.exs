defmodule Loopex.ToolCallReaderTest do
  @moduledoc """
  ## Concept

  Proves the tool-call field reader and the guards that depend on it refuse the
  documents that previously slipped past them. Each case names a way a document
  could disagree with a real JSON parser, or a way a reader failure could be read
  as permission, because every one of those was a live bypass rather than a
  hypothetical.

  ## Technical depth

  The scripts are executed as the client executes them -- the hook as its own
  executable, reading the document on standard input -- so a lost execute bit, a
  broken shebang, or a status the client does not treat as blocking fails here.
  Only exit 2 blocks in Claude Code, so a case that merely asserts "non-zero"
  would pass on a status that permits the call; every blocking assertion names 2
  exactly. Documents are built at runtime rather than stored as fixtures, because
  the accepted gate locks the digests of the fixtures under
  `scripts/fixtures/hook-cases` and those bytes may not change for this milestone.
  """

  use ExUnit.Case, async: true

  @moduletag :tool_call_reader

  alias Loopex.Checks.Json

  setup_all do
    root = LoopexTest.Repo.root()

    # Built here rather than written literally so the string that must never be
    # touched is not itself sitting in a source file that tools scan.
    real_home = Path.join(String.trim_trailing(System.get_env("HOME"), "/"), "." <> "loopex")

    {:ok,
     root: root,
     reader: Path.join(root, "scripts/json-field.sh"),
     bash_guard: Path.join(root, ".claude/hooks/guard-bash.sh"),
     fs_guard: Path.join(root, ".claude/hooks/guard-filesystem.sh"),
     real_home: real_home,
     hook_timeout_ms: guard_timeout_ms(root)}
  end

  # The smallest timeout the client applies to a guard, in milliseconds.
  #
  # Technical depth: read from the configuration rather than restated in the test,
  # because a budget written down twice drifts, and the copy in the test is the one
  # that goes stale silently -- it keeps passing while the real hook is being
  # killed. Every registered guard is considered and the tightest wins, since the
  # reader has to fit inside whichever one runs it.
  defp guard_timeout_ms(root) do
    {:ok, settings} =
      root
      |> Path.join(".claude/settings.json")
      |> File.read!()
      |> Json.decode()

    settings
    |> Map.get("hooks", %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(&Map.get(&1, "hooks", []))
    |> Enum.filter(&String.contains?(Map.get(&1, "command", ""), "guard-"))
    |> Enum.map(&Map.get(&1, "timeout"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> raise "no guard timeout found in .claude/settings.json; the budget is unknown"
      timeouts -> Enum.min(timeouts) * 1_000
    end
  end

  # Runs an executable with `document` on standard input and returns {output, status}.
  #
  # Technical depth: the document is staged in a file and redirected rather than
  # written to a port, because an Erlang port cannot close only the standard input
  # of a spawned executable -- a reader that waits for end-of-file never sees one
  # and the case times out instead of testing anything. `exec` replaces the shell,
  # so the hook is still reached through `execve` and a lost execute bit or broken
  # shebang still fails here.
  defp feed(executable, args, document) do
    path =
      Path.join(
        System.tmp_dir!(),
        "loopex-tool-call-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, document)

    try do
      command =
        [executable | args]
        |> Enum.map_join(" ", &shell_quote/1)
        |> then(&"exec #{&1} < #{shell_quote(path)} 2>&1")

      System.cmd("/bin/sh", ["-c", command], stderr_to_stdout: true)
    after
      File.rm(path)
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  describe "the reader agrees with a real JSON parser about which binding wins" do
    test "a repeated parent object discards what the earlier one bound", %{reader: reader} do
      # A real parser keeps the LAST tool_input, so a document whose second parent
      # never binds the requested key has no value for it at all.
      #
      # Technical depth: the second parent must bind a DIFFERENT key for this to
      # reach the parent reset. When both parents bind `command`, last-wins for
      # duplicate keys already clears the earlier one, and the case still passes
      # with the parent reset removed -- it reads like a bypass test and proves
      # nothing. Removing `delete found` changes only this shape.
      document = ~s({"tool_input":{"command":"git status"},"tool_input":{"path":"/x"}})

      assert {output, 0} = feed(reader, ["tool_input", "command"], document)

      assert String.trim(output) == "",
             "a value bound under a discarded parent must not survive into the answer"
    end

    test "a repeated parent cannot hide the object that takes effect", %{
      reader: reader,
      real_home: real_home
    } do
      # The bypass the rule was written for: a harmless object first, the one a
      # real parser actually uses second.
      document =
        ~s({"tool_input":{"command":"git status"},"tool_input":{"command":"#{real_home}/x"}})

      assert {output, 0} = feed(reader, ["tool_input", "command"], document)
      assert String.trim(output) == "#{real_home}/x"
    end

    test "a non-string duplicate discards the string bound earlier", %{reader: reader} do
      # Only a string value used to set the binding, so a later null, number,
      # object, or array left the earlier string in place -- a document could pin
      # a harmless value with a duplicate a real parser would have taken.
      for later <- ["null", "7", "{}", "[]"] do
        document = ~s({"tool_input":{"command":"git status","command":#{later}}})
        assert {output, 0} = feed(reader, ["tool_input", "command"], document)

        assert String.trim(output) == "",
               "a later #{later} must discard the earlier string, not leave it bound"
      end
    end
  end

  describe "the reader fails closed rather than returning something it could not read" do
    test "an oversize value is refused instead of truncated", %{reader: reader} do
      # The bound exists so a pathological value cannot be assembled piece by
      # piece. If an oversize string turns out to BE the requested value, a
      # truncated answer would be worse than no answer: the guard would scan a
      # prefix and allow whatever the tail contained.
      document = ~s({"tool_input":{"command":"#{String.duplicate("x", 70_000)}"}})

      assert {output, status} = feed(reader, ["tool_input", "command"], document)
      assert status == 65, "an unreadable field must exit non-zero, not report success"
      assert output =~ "too large to read safely"
    end

    test "a value with more pieces than the cap is refused, not assembled", %{reader: reader} do
      # The piece cap, not the assembly strategy, is what bounds this shape. Half a
      # million escaped quotes took about thirty seconds -- past the hook timeout,
      # where the client does not block -- and the cap is what makes that
      # unreachable. A value the cap rejects must fail closed like any other
      # unreadable field.
      document = ~s({"tool_input":{"command":"#{String.duplicate("\\\"", 5_000)}"}})

      assert {output, status} = feed(reader, ["tool_input", "command"], document)
      assert status == 65, "a value past the piece cap must be refused, not truncated"
      assert output =~ "too large to read safely"
    end

    test "a value just under the cap is read correctly, well inside the hook budget", %{
      reader: reader,
      hook_timeout_ms: budget
    } do
      # 4,095 pieces: the largest a document can carry and still be answered.
      #
      # What this proves and what it does not. The exactness assertion is the
      # load-bearing half -- it fails on a truncated or re-escaped value. The
      # elapsed bound is coarse: with the cap in place no legal input is large
      # enough for quadratic assembly to blow the budget, so this would still pass
      # against repeated concatenation. The cap is what makes the historical case
      # unreachable, and the test above is what holds the cap. Both are kept
      # because the budget is the property the client actually enforces.
      #
      # The budget is read from the client configuration rather than restated, so
      # it cannot drift from the timeout that kills the hook. A reader that
      # outlives it is killed by the client -- the exit-124 outcome that does not
      # block -- and no reader status then exists for a guard to translate, so the
      # status handling does not save it.
      quotes = 4_094
      document = ~s({"tool_input":{"command":"#{String.duplicate("\\\"", quotes)}"}})

      task = Task.async(fn -> feed(reader, ["tool_input", "command"], document) end)
      allowed = div(budget, 2)

      assert {:ok, {output, 0}} =
               Task.yield(task, allowed) || Task.shutdown(task, :brutal_kill),
             "the reader did not answer within #{allowed}ms, half the #{budget}ms hook budget"

      assert String.trim_trailing(output, "\n") == String.duplicate("\"", quotes),
             "the value must be assembled exactly, not truncated or re-escaped"
    end
  end

  describe "a guard translates a reader failure into the only blocking status" do
    test "the bash guard blocks when the reader cannot read the field", %{
      bash_guard: guard,
      real_home: real_home
    } do
      # The reader announced it could not read the field and exited non-zero, and
      # the guard took the empty output as "no such field" and allowed the call.
      document = ~s({"tool_input":{"command":"#{String.duplicate("y", 70_000)} #{real_home}/x"}})

      assert {output, 2} = feed(guard, [], document)
      assert output =~ "Blocked"
    end

    test "the filesystem guard blocks when the reader cannot read the field", %{
      fs_guard: guard,
      real_home: real_home
    } do
      document = ~s({"tool_input":{"path":"#{String.duplicate("y", 70_000)}#{real_home}"}})

      assert {output, 2} = feed(guard, [], document)
      assert output =~ "Blocked"
    end
  end

  describe "the guards block every spelling of a real state directory" do
    test "the bash guard blocks each spelling and allows ordinary work", %{
      bash_guard: guard,
      real_home: real_home
    } do
      for spelling <- ["~/." <> "loopex", "$HOME/." <> "loopex", real_home] do
        document = ~s({"tool_input":{"command":"cat #{spelling}/journal"}})
        assert {_output, 2} = feed(guard, [], document), "#{spelling} must be blocked"
      end

      assert {_output, 0} = feed(guard, [], ~s({"tool_input":{"command":"git status"}}))
    end

    test "the filesystem guard blocks a path reached through a duplicate parent", %{
      fs_guard: guard,
      real_home: real_home
    } do
      # The bypass that motivated last-wins at the parent level, and the only shape
      # that reaches it through a guard.
      #
      # Technical depth: this guard asks for `file_path notebook_path path` in
      # priority order, so the discarded parent must bind a HIGHER-priority field
      # than the surviving one. With both parents binding `path`, the duplicate-key
      # rule already clears the first and the case passes with the parent reset
      # deleted -- the same vacuity the reader's own parent test documents. Here,
      # deleting `delete found` leaves `file_path` bound to /tmp/safe from the
      # discarded object; it outranks the real `path`, and the guard allows a call
      # that reads the protected journal.
      document =
        ~s({"tool_input":{"file_path":"/tmp/safe"},) <>
          ~s("tool_input":{"path":"#{real_home}/journal"}})

      assert {_output, 2} = feed(guard, [], document)
    end
  end
end

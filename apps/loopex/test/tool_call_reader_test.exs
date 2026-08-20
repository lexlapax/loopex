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
     real_home: real_home}
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

    test "a value built from many escaped quotes is read in linear time", %{reader: reader} do
      # Splitting on the quote made the scan linear, but each escaped quote still
      # extended a growing string, so this shape was quadratic again -- about
      # thirty seconds, past the hook timeout, where the client does not block.
      # The bound is generous: it catches a return to quadratic work without
      # depending on the speed of the machine running the suite.
      document = ~s({"tool_input":{"command":"#{String.duplicate("\\\"", 4_094)}"}})

      task = Task.async(fn -> feed(reader, ["tool_input", "command"], document) end)

      assert {:ok, {_output, _status}} =
               Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill),
             "the reader did not finish within 20s; the quadratic work is back"
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
      # The bypass that motivated last-wins at the parent level: a harmless object
      # first, the real one second.
      document =
        ~s({"tool_input":{"path":"/tmp/safe"},"tool_input":{"path":"#{real_home}/journal"}})

      assert {_output, 2} = feed(guard, [], document)
    end
  end
end

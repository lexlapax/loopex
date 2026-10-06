defmodule Loopex.Executor.Local.ReadOnlyToolsTest do
  use ExUnit.Case, async: true
  alias Loopex.Executor.Local.{CodingTools, ReadOnlyTools, ToolGlob}

  setup context do
    if context[:short_workspace] do
      {:ok, root: short_workspace!()}
    else
      root = Path.join(System.tmp_dir!(), "loopex-read-only-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end
  end

  # Concept: physical path limits remain separate from relative traversal budgets.
  # Technical depth: only the socket and exact raw-path-byte witnesses use this
  # short root. The existing OS temp parent must be a directory, and mkdir
  # exclusively claims a random name before any fixture file is written.
  defp short_workspace! do
    %File.Stat{type: :directory} = File.stat!("/tmp")
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join("/tmp", "loopex-ro-" <> suffix)
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp execute(root, kind, arguments, limit \\ 16_384) do
    {:ok, admitted} = ReadOnlyTools.arguments("loopex." <> kind, arguments)
    ReadOnlyTools.execute(root, admitted, limit)
  end

  test "a filesystem-root workspace admits descendants", %{root: root} do
    File.write!(Path.join(root, "needle.txt"), "found\n")
    {:ok, canonical_root} = CodingTools.resolve(root, ".")
    relative = Path.relative_to(canonical_root, "/")

    assert {:completed, output} = execute("/", "ls", %{"path" => relative})
    assert output =~ "needle.txt"
  end

  test "glob grammar anchors Unicode scalars, classes, quoting, dotfiles and zero-segment double star" do
    for {pattern, yes, no} <- [
          {"**/x", ["x", ".hidden/x", "a/b/x"], ["xx", "a/x/y"]},
          {"a/**", ["a", "a/x", "a/x/y"], ["ab", "b/a"]},
          {"a/**/b", ["a/b", "a/x/b", "a/x/y/b"], ["a/b/c", "a//b"]},
          {"?", ["é", "."], ["éx", "x/y"]},
          {"*", [".hidden", "é"], ["a/b"]},
          {"[a-c]", ["a", "b", "c"], ["d", "/"]},
          {"[^a-c]", ["é", "."], ["a", "/"]},
          {"[-a]", ["-", "a"], ["b"]},
          {"[a-]", ["-", "a"], ["b"]},
          {"[\\^\\-\\]]", ["^", "-", "]"], ["a"]},
          {"\\*\\?", ["*?"], ["ab"]},
          {"a\\/b.txt", ["a/b.txt"], ["ab.txt", "a/x/b.txt"]}
        ] do
      assert {:ok, matcher} = ToolGlob.compile(pattern)
      for path <- yes, do: assert(Regex.match?(matcher, path), "#{pattern} should match #{path}")
      for path <- no, do: refute(Regex.match?(matcher, path), "#{pattern} should refuse #{path}")
    end

    for pattern <- [
          "",
          ".",
          "..",
          "a/./b",
          "a/../b",
          "/a",
          "a/",
          "a//b",
          "a**",
          "***",
          "x/**y",
          "[]",
          "[^]",
          "[z-a]",
          "[a/b]",
          "[a\\/b]",
          "[a",
          "a\\",
          "[a\\"
        ] do
      assert {:error, _} = ToolGlob.compile(pattern), "invalid glob admitted: #{inspect(pattern)}"
    end
  end

  test "quoted slash matches a workspace-relative path in grep and find", %{root: root} do
    File.mkdir!(Path.join(root, "a"))
    File.write!(Path.join(root, "a/b.txt"), "needle\n")

    assert {:completed, "M\ta/b.txt\t1\tneedle\n"} =
             execute(root, "grep", %{"pattern" => "needle", "glob" => "a\\/b.txt"})

    assert {:completed, "P\ta/b.txt\n"} =
             execute(root, "find", %{"pattern" => "a\\/b.txt"})
  end

  test "encoding preserves printable bytes and encodes every record delimiter and UTF-8 byte" do
    assert ReadOnlyTools.encode(" %\t\r\né\0\x7F~") == " %25%09%0D%0A%C3%A9%00%7F~"

    for byte <- 0..127 do
      actual = ReadOnlyTools.encode(<<byte>>)

      if byte in 32..126 and byte != ?%,
        do: assert(actual == <<byte>>),
        else: assert(byte_size(actual) == 3)
    end

    refute ReadOnlyTools.encode("%09") == ReadOnlyTools.encode("\t")
  end

  test "glob classes refuse leftover interior unescaped hyphens after a range" do
    for pattern <- ["[a-b-c]", "[a-b--]", "[a-b--c]", "[^a-b-c]"] do
      assert {:error, :invalid_glob} = ToolGlob.compile(pattern)
    end

    for {pattern, values} <- [
          {"[-a]", ["-", "a"]},
          {"[a-]", ["-", "a"]},
          {"[a-b-]", ["-", "a", "b"]},
          {"[a\\-c]", ["-", "a", "c"]},
          {"[--a]", ["-", "0", "A", "a"]},
          {"[---]", ["-"]},
          {"[\\--a]", ["-", "0", "A", "a"]},
          {"[a-bc-d]", ["a", "b", "c", "d"]}
        ] do
      assert {:ok, matcher} = ToolGlob.compile(pattern)
      for value <- values, do: assert(Regex.match?(matcher, value))
      refute Regex.match?(matcher, "z")
    end
  end

  @tag :short_workspace
  test "real FIFO socket and symlinks are entries and grep never opens them", %{root: root} do
    fifo = Path.join(root, "fifo")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    socket_path = Path.join(root, "socket")

    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, socket_path}}, {:active, false}])

    on_exit(fn -> :gen_tcp.close(socket) end)

    outside =
      Path.join(
        System.tmp_dir!(),
        "loopex-read-only-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "secret"), "match")
    File.ln_s!(outside, Path.join(root, "link"))
    File.write!(Path.join(root, "ok"), "match")

    assert {:completed, "P\tfifo\nP\tlink\nP\tok\nP\tsocket\n"} =
             execute(root, "find", %{"pattern" => "**"})

    assert {:completed, "P\tfifo\nP\tlink\nP\tok\nP\tsocket\n"} =
             execute(root, "ls", %{"recursive" => true})

    assert {:completed, "M\tok\t1\tmatch\n"} = execute(root, "grep", %{"pattern" => "match"})

    for path <- ["fifo", "socket", "link"] do
      assert {:completed, ""} = execute(root, "grep", %{"pattern" => ".", "path" => path})

      assert {:completed, output} = execute(root, "find", %{"pattern" => "**", "path" => path})
      assert output == "P\t#{path}\n"
    end

    assert ReadOnlyTools.classify(%File.Stat{type: :device}) == :special
  end

  test "invalid raw names spend traversal budget and produce one aggregate notice", %{root: root} do
    created = :file.write_file(root <> "/" <> <<255>>, "match")
    File.write!(Path.join(root, "tab\t%é"), "match")
    assert {:completed, output} = execute(root, "find", %{"pattern" => "**"})

    case created do
      :ok ->
        assert output ==
                 "P\ttab%09%25%C3%A9\nN\tskipped\tinvalid_name=1\ttoo_large=0\tinvalid_utf8=0\tchanged=0\tunreadable=0\n"

      {:error, :eilseq} ->
        assert {:unix, :darwin} = :os.type()
        assert output == "P\ttab%09%25%C3%A9\n"

        IO.puts(
          "READ_ONLY_WITNESS_UNAVAILABLE invalid_name: Darwin filesystem rejected raw invalid UTF-8 filename with eilseq; Linux witness remains required"
        )
    end
  end

  test "result records fit exactly below the permanent 107-byte reservation", %{root: root} do
    # M, tabs, one-character path, decimal line number and LF cost seven bytes.
    File.write!(Path.join(root, "x"), String.duplicate("a", 16_277 - 7))
    assert {:completed, exact} = execute(root, "grep", %{"pattern" => "."})
    assert byte_size(exact) == 16_277
    refute exact =~ "N\t"
    File.write!(Path.join(root, "x"), String.duplicate("a", 16_277 - 6))
    assert {:completed, "N\ttruncated\n"} = execute(root, "grep", %{"pattern" => "."})
    File.write!(Path.join(root, "x"), "é")
    assert {:completed, "N\ttruncated\n"} = execute(root, "grep", %{"pattern" => "."}, 119)
    assert {:completed, "M\tx\t1\t%C3%A9\n"} = execute(root, "grep", %{"pattern" => "."}, 120)
  end

  test "grep lines are complete, LF is removed, CR remains and regex is per line", %{root: root} do
    File.write!(Path.join(root, "x"), "a\r\na a\n\nlast")

    assert {:completed, "M\tx\t1\ta%0D\nM\tx\t2\ta a\nM\tx\t3\t\nM\tx\t4\tlast\n"} =
             execute(root, "grep", %{"pattern" => ".*"})

    assert {:completed, ""} = execute(root, "grep", %{"pattern" => "a\\na"})
    File.write!(Path.join(root, "x"), "")
    assert {:completed, ""} = execute(root, "grep", %{"pattern" => ".*"})
  end

  test "grep glob filters use workspace-relative paths for requested subdirectories", %{
    root: root
  } do
    File.mkdir!(Path.join(root, "a"))
    File.write!(Path.join(root, "a/x.txt"), "match")
    File.write!(Path.join(root, "a/x.md"), "match")
    File.write!(Path.join(root, "root.txt"), "match")

    assert {:completed, "M\ta/x.md\t1\tmatch\nM\ta/x.txt\t1\tmatch\nM\troot.txt\t1\tmatch\n"} =
             execute(root, "grep", %{"pattern" => "."})

    assert {:completed, "M\troot.txt\t1\tmatch\n"} =
             execute(root, "grep", %{"pattern" => ".", "glob" => "*"})

    assert {:completed, ""} = execute(root, "grep", %{"pattern" => ".", "glob" => "nomatch"})

    assert {:completed, "M\ta/x.txt\t1\tmatch\n"} =
             execute(root, "grep", %{"pattern" => ".", "path" => "a", "glob" => "**/*.txt"})

    assert {:completed, ""} =
             execute(root, "grep", %{"pattern" => ".", "path" => "a", "glob" => "*.txt"})
  end

  test "all admitted string bounds count UTF-8 bytes and admit exactly 4096" do
    exact = String.duplicate("é", 2048)
    assert byte_size(exact) == 4096

    assert {:ok, _} =
             ReadOnlyTools.arguments("loopex.grep", %{
               "pattern" => exact,
               "glob" => exact,
               "path" => exact
             })

    for key <- ["pattern", "glob", "path"] do
      arguments = Map.put(%{"pattern" => "."}, key, exact <> "x")
      assert {:error, :invalid_tool_arguments} = ReadOnlyTools.arguments("loopex.grep", arguments)
    end
  end

  test "file byte ceiling is inclusive and invalid UTF-8 discards all matches", %{root: root} do
    File.write!(Path.join(root, "x"), String.duplicate("a", 1_048_576))
    assert {:completed, ""} = execute(root, "grep", %{"pattern" => "z"})
    File.write!(Path.join(root, "x"), String.duplicate("a", 1_048_577))

    assert {:completed,
            "N\tskipped\tinvalid_name=0\ttoo_large=1\tinvalid_utf8=0\tchanged=0\tunreadable=0\n"} =
             execute(root, "grep", %{"pattern" => "z"})

    File.write!(Path.join(root, "x"), "match\n" <> <<255>>)

    assert {:completed,
            "N\tskipped\tinvalid_name=0\ttoo_large=0\tinvalid_utf8=1\tchanged=0\tunreadable=0\n"} =
             execute(root, "grep", %{"pattern" => "match"})
  end

  test "both open-handle and path observations must remain regular with the exact device inode size tuple" do
    before = %File.Stat{type: :regular, major_device: 1, inode: 2, size: 3}
    assert ReadOnlyTools.same_file?(before, before, before)

    for changed <- [
          %{before | type: :symlink},
          %{before | type: :directory},
          %{before | type: :device},
          %{before | inode: 4},
          %{before | major_device: 4},
          %{before | size: 4}
        ] do
      refute ReadOnlyTools.same_file?(before, changed, before)
      refute ReadOnlyTools.same_file?(before, before, changed)
    end

    assert ReadOnlyTools.same_file?(before, %{before | mtime: 4}, %{before | mtime: 5})
  end

  test "unreadable requested roots fail and unreadable descendants count one notice", %{
    root: root
  } do
    directory = Path.join(root, "locked")
    File.mkdir!(directory)
    File.write!(Path.join(directory, "x"), "match")
    File.chmod!(directory, 0)
    on_exit(fn -> File.chmod(directory, 0o700) end)

    for {kind, args} <- [
          {"grep", %{"pattern" => "."}},
          {"find", %{"pattern" => "**"}},
          {"ls", %{}}
        ] do
      assert {:failed, message} = execute(root, kind, Map.put(args, "path", "locked"))
      assert message == "#{kind} failed: requested path unavailable"
    end

    notice = "N\tskipped\tinvalid_name=0\ttoo_large=0\tinvalid_utf8=0\tchanged=0\tunreadable=1\n"
    assert {:completed, ^notice} = execute(root, "grep", %{"pattern" => "."})
    assert {:completed, output} = execute(root, "find", %{"pattern" => "**"})
    assert output == "P\tlocked\n" <> notice
    assert {:completed, "P\tlocked/\n"} = execute(root, "ls", %{})
    assert {:completed, output} = execute(root, "ls", %{"recursive" => true})
    assert output == "P\tlocked/\n" <> notice
    File.chmod!(directory, 0o700)
    File.chmod!(Path.join(directory, "x"), 0)

    assert {:failed, "grep failed: requested path unavailable"} =
             execute(root, "grep", %{"pattern" => ".", "path" => "locked/x"})

    assert {:completed, ^notice} = execute(root, "grep", %{"pattern" => "."})
  end

  test "grep admits exactly 1000 records then notices only an additional eligible result", %{
    root: root
  } do
    File.write!(Path.join(root, "x"), String.duplicate("a\n", 1000))
    assert {:completed, exact} = execute(root, "grep", %{"pattern" => "."})
    assert length(String.split(exact, "\n", trim: true)) == 1000
    refute exact =~ "N\ttruncated"
    File.write!(Path.join(root, "x"), String.duplicate("a\n", 1001))
    assert {:completed, extra} = execute(root, "grep", %{"pattern" => "."})
    assert extra == exact <> "N\ttruncated\n"
  end

  test "find admits exactly 2000 records and traversal continues after its result ceiling", %{
    root: root
  } do
    for number <- 1..2000,
        do:
          File.write!(Path.join(root, String.pad_leading(Integer.to_string(number), 4, "0")), "")

    assert {:completed, exact} = execute(root, "find", %{"pattern" => "*"})
    assert length(String.split(exact, "\n", trim: true)) == 2000
    refute exact =~ "N\ttruncated"
    File.write!(Path.join(root, "z"), "")
    assert {:completed, extra} = execute(root, "find", %{"pattern" => "*"})
    assert extra == exact <> "N\ttruncated\n"
    assert {:completed, "P\tz\n"} = execute(root, "find", %{"pattern" => "z"})
  end

  test "recursive depth ceilings include the directory but do not enumerate it", %{root: root} do
    for depth <- 1..33, do: File.mkdir_p!(Path.join([root | List.duplicate("x", depth)]))
    assert {:completed, shallow} = execute(root, "ls", %{})
    assert shallow == "P\tx/\n"
    assert {:completed, recursive} = execute(root, "ls", %{"recursive" => true})

    expected =
      for depth <- 1..8,
          into: "",
          do: "P\t" <> Enum.join(List.duplicate("x", depth), "/") <> "/\n"

    assert recursive == expected <> "N\ttruncated\n"
    assert {:completed, deep} = execute(root, "find", %{"pattern" => "**"})
    assert length(String.split(deep, "\n", trim: true)) == 33
    assert String.ends_with?(deep, "N\ttruncated\n")
    assert {:completed, "N\ttruncated\n"} = execute(root, "grep", %{"pattern" => "."})
  end

  test "cumulative file bytes admit exactly 16 MiB and count bytes from invalid files", %{
    root: root
  } do
    for number <- 1..16 do
      File.write!(
        Path.join(root, String.pad_leading(Integer.to_string(number), 2, "0")),
        String.duplicate("a", 1_048_576)
      )
    end

    assert {:completed, ""} = execute(root, "grep", %{"pattern" => "z"})
    File.write!(Path.join(root, "z"), "z")
    assert {:completed, "N\ttruncated\n"} = execute(root, "grep", %{"pattern" => "z"})
    File.write!(Path.join(root, "01"), <<255>> <> String.duplicate("a", 1_048_575))

    assert {:completed,
            "N\tskipped\tinvalid_name=0\ttoo_large=0\tinvalid_utf8=1\tchanged=0\tunreadable=0\nN\ttruncated\n"} =
             execute(root, "grep", %{"pattern" => "z"})
  end

  test "aggregate truncation detects malformed UTF-8 in an unfinished line and discards only that file",
       %{
         root: root
       } do
    write_aggregate_prefix!(root, 64)

    for suffix <- [
          <<255>>,
          <<0x80>>,
          <<0xC0>>,
          <<0xF5>>,
          <<0xE0, 0x80>>,
          <<0xED, 0xA0>>,
          <<0xF0, 0x80>>,
          <<0xF4, 0x90>>,
          <<0xE2, 0x28>>,
          <<0xC2, 0x80, 255>>
        ] do
      prefix = "staged\n" <> String.duplicate("a", 57 - byte_size(suffix)) <> suffix
      assert byte_size(prefix) == 64
      File.write!(Path.join(root, "z"), prefix <> "x")

      assert {:completed,
              "M\t00\t1\tkeep\nN\tskipped\tinvalid_name=0\ttoo_large=0\tinvalid_utf8=1\tchanged=0\tunreadable=0\nN\ttruncated\n"} =
               execute(root, "grep", %{"pattern" => "keep|staged"})
    end
  end

  test "aggregate cap accepts a valid incomplete scalar prefix and excludes its witness byte", %{
    root: root
  } do
    write_aggregate_prefix!(root, 64)

    for {suffix, witness} <- [
          {"", <<255>>},
          {<<0xC2>>, <<0xA9>>},
          {<<0xE0>>, <<0xA0>>},
          {<<0xE0, 0xA0>>, <<0x80>>},
          {<<0xE2>>, <<0x82>>},
          {<<0xE2, 0x82>>, <<0xAC>>},
          {<<0xED>>, <<0x9F>>},
          {<<0xED, 0x9F>>, <<0xBF>>},
          {<<0xF0>>, <<0x90>>},
          {<<0xF0, 0x90>>, <<0x80>>},
          {<<0xF0, 0x90, 0x80>>, <<0x80>>},
          {<<0xF1>>, <<0x80>>},
          {<<0xF1, 0x80>>, <<0x80>>},
          {<<0xF1, 0x80, 0x80>>, <<0x80>>},
          {<<0xF4>>, <<0x8F>>},
          {<<0xF4, 0x8F>>, <<0xBF>>},
          {<<0xF4, 0x8F, 0xBF>>, <<0xBF>>},
          {<<0xE2, 0x82, 0xAC>>, <<255>>}
        ] do
      prefix = "staged\n" <> String.duplicate("a", 57 - byte_size(suffix)) <> suffix
      assert byte_size(prefix) == 64
      File.write!(Path.join(root, "z"), prefix <> witness)

      assert {:completed, "M\t00\t1\tkeep\nM\tz\t1\tstaged\nN\ttruncated\n"} =
               execute(root, "grep", %{"pattern" => "keep|staged"})
    end
  end

  defp write_aggregate_prefix!(root, remaining) do
    full = String.duplicate(String.duplicate("a", 8191) <> "\n", 128)
    assert byte_size(full) == 1_048_576

    File.write!(Path.join(root, "00"), "keep\n" <> binary_part(full, 5, byte_size(full) - 5))

    for number <- 1..14,
        do:
          File.write!(
            Path.join(root, String.pad_leading(Integer.to_string(number), 2, "0")),
            full
          )

    File.write!(Path.join(root, "15"), binary_part(full, 0, byte_size(full) - remaining))
  end

  test "inspected entry limit admits entry 10000 and refuses entry 10001", %{root: root} do
    for number <- 1..9999,
        do:
          File.write!(Path.join(root, String.pad_leading(Integer.to_string(number), 5, "0")), "")

    File.write!(Path.join(root, "z"), "")
    assert {:completed, "P\tz\n"} = execute(root, "find", %{"pattern" => "z"})
    File.write!(Path.join(root, "a"), "")
    assert {:completed, "N\ttruncated\n"} = execute(root, "find", %{"pattern" => "z"})
  end

  @tag :short_workspace
  test "cumulative raw path bytes admit exactly 8 MiB before the next entry", %{root: root} do
    relative = Enum.join(List.duplicate(String.duplicate("d", 250), 3), "/")
    directory = Path.join(root, relative)
    File.mkdir_p!(directory)

    for number <- 1..9361 do
      name =
        String.pad_leading(Integer.to_string(number), 143, "0") <>
          if(number <= 16, do: String.duplicate("x", 16), else: "")

      File.write!(Path.join(directory, name), "")
    end

    target = "z" <> String.duplicate("0", 142)
    File.write!(Path.join(directory, target), "")
    assert 9362 * 896 + 16 * 16 == 8_388_608

    assert {:completed, output} =
             execute(root, "find", %{"pattern" => "**/z*", "path" => relative})

    assert output == "P\t#{relative}/#{target}\n"
    File.write!(Path.join(directory, "a" <> String.duplicate("0", 142)), "")

    assert {:completed, "N\ttruncated\n"} =
             execute(root, "find", %{"pattern" => "**/z*", "path" => relative})
  end
end

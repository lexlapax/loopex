defmodule Loopex.M0ChildEnvironmentCheck do
  @moduledoc false

  # Concept: these are four reviewed constructor occurrences, not file exemptions.
  # Technical depth: the existing Git matcher supplies NUL-delimited paths and
  # line numbers. We parse candidate Elixir without evaluating it, identify the
  # enclosing definition, and pin the constructor and immediate use. This is
  # structural drift protection, not general shell or Elixir dataflow analysis.
  @launcher "apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/provider_launcher.ex"
  @fixture "apps/loopex_llm_reqllm/test/support/provider_build_fixture.exs"

  @vector ~S"""
  {"/usr/bin/env",
   ["-i", "PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C",
    "ERL_CRASH_DUMP=/dev/null", "ERL_CRASH_DUMP_SECONDS=0", "/bin/sh", "-c",
    carrier_program(), "loopex-provider-carrier", guard_program(),
    namespace.namespace, nonce, Integer.to_string(cleanup_grace_ms),
    configuration.interpreter_path, configuration.worker_path,
    namespace.socket_path, configuration.build_manifest_sha256,
    Integer.to_string(deadline)]}
  """

  @worker_command ~S"""
  /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
    "$interpreter" "$worker" "$socket" "$nonce" "$manifest" "$deadline" \
    3<&- 4>&- </dev/null >/dev/null 2>&1 &
  """

  @build ~S"""
  environment =
    empty_environment()
    |> Map.merge(%{
      "PATH" => Enum.join([Path.join(elixir_root, "bin"), otp_bin, "/usr/bin", "/bin"], ":"),
      "HOME" => Path.join(build, "home"), "TMPDIR" => Path.join(build, "tmp"),
      "MIX_ENV" => "test", "MIX_BUILD_PATH" => build,
      "MIX_DEPS_PATH" => Path.join(build, "deps"),
      "MIX_HOME" => Path.join(build, "mix-home"),
      "MIX_ARCHIVES" => Path.join(build, "mix-home/archives"),
      "HEX_HOME" => Path.join(build, "hex"), "HEX_OFFLINE" => "1",
      "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
      "ERL_CRASH_DUMP" => "/dev/null", "ERL_CRASH_DUMP_SECONDS" => "0",
      "GIT_OPTIONAL_LOCKS" => "0"
    })
  {output, status} =
    System.cmd("/bin/sh",
      ["-c", "exec \"$1\" \"$2\" loopex.provider.build </dev/null",
       "provider-build", elixir, mix],
      cd: Path.join(@source_root, "apps/loopex_llm_reqllm"),
      env: Map.to_list(environment), stderr_to_stdout: true)
  """

  @git ~S"""
  environment =
    empty_environment()
    |> Map.merge(%{"PATH" => "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS" => "0"})
    |> Map.to_list()
  {status, 0} =
    System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"],
      cd: @source_root, env: environment)
  unless status == "", do: raise("provider fixture requires a clean source checkout")
  {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: @source_root, env: environment)
  String.trim(source)
  """

  def check(root, matches) when is_binary(root) and is_binary(matches) do
    try do
      records = records!(matches, [])
      unique = Enum.uniq_by(records, fn {path, line, _text} -> {path, line} end)
      require!(length(unique) == length(records), "duplicate matcher record")

      allowed =
        records
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.flat_map(fn
          @launcher -> launcher!(root)
          @fixture -> fixture!(root)
          _unregistered -> []
        end)
        |> MapSet.new()

      Enum.each(records, fn {path, line, text} ->
        require!(
          MapSet.member?(allowed, {path, line, text}),
          "#{inspect(path)}:#{line}: unregistered search-path construction"
        )
      end)

      {:ok, length(records)}
    rescue
      error ->
        {:error, "child-environment inspection unavailable (#{inspect(error.__struct__)})"}
    catch
      {:refused, reason} -> {:error, reason}
    end
  end

  # Git -z separates path and number with NUL, and terminates source lines with
  # LF. Parsing that framing retains colons/newlines in filenames without ever
  # evaluating a candidate path. Only the two constant paths above are opened.
  defp records!("", acc), do: Enum.reverse(acc)

  defp records!(bytes, acc) do
    with [path, rest] <- :binary.split(bytes, <<0>>),
         [number, rest] <- :binary.split(rest, <<0>>),
         {line, ""} when line > 0 <- Integer.parse(number),
         [text, rest] <- :binary.split(rest, "\n"),
         true <- path != "" do
      records!(rest, [{path, line, text} | acc])
    else
      _invalid -> throw({:refused, "malformed Git matcher record"})
    end
  end

  defp launcher!(root) do
    {lines, forms} = source!(root, @launcher, [:Loopex, :LLM, :ReqLLM, :ProviderLauncher])
    vector = definition!(forms, :def, :vector, 5, @launcher)

    require!(
      normalized(vector.body) == expected(@vector),
      "#{@launcher}: vector/5 context changed"
    )

    guard = definition!(forms, :defp, :guard_program, 0, @launcher)

    command =
      case guard.body do
        {:sigil_S, _, [{:<<>>, _, [literal]}, []]} when is_binary(literal) ->
          literal

        _other ->
          throw({:refused, "#{@launcher}: guard_program/0 is not one literal shell program"})
      end

    # Unrelated cleanup code is not pinned. This one complete worker-launch
    # command must occur once as reviewed, including private-FD closure.
    require!(
      length(:binary.matches(command, @worker_command)) == 1,
      "#{@launcher}: guard_program/0 worker command changed or duplicated"
    )

    [
      occurrence!(lines, vector, ~s("PATH=/usr/bin:/bin",), @launcher),
      occurrence!(lines, guard, @worker_command |> String.split("\n") |> hd(), @launcher)
    ]
  end

  defp fixture!(root) do
    {lines, forms} = source!(root, @fixture, [:Loopex, :LLM, :ReqLLM, :ProviderBuildFixture])
    build = definition!(forms, :defp, :build!, 1, @fixture)
    expected_build = expressions(expected(@build))

    sequences =
      build.body
      |> normalized()
      |> expressions()
      |> Enum.chunk_every(length(expected_build), 1, :discard)
      |> Enum.count(&(&1 == expected_build))

    require!(
      sequences == 1,
      "#{@fixture}: build!/1 construction/use context changed or duplicated"
    )

    git = definition!(forms, :defp, :clean_source!, 0, @fixture)

    require!(
      normalized(git.body) == expected(@git),
      "#{@fixture}: clean_source!/0 context changed"
    )

    [
      occurrence!(
        lines,
        build,
        ~s'"PATH" => Enum.join([Path.join(elixir_root, "bin"), otp_bin, "/usr/bin", "/bin"], ":"),',
        @fixture
      ),
      occurrence!(
        lines,
        git,
        ~s'|> Map.merge(%{"PATH" => "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS" => "0"})',
        @fixture
      )
    ]
  end

  defp source!(root, path, module) do
    full = Path.join(root, path)

    require!(
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(full)),
      "#{path}: expected readable regular source"
    )

    source = File.read!(full)

    require!(
      String.valid?(source) and not String.contains?(source, ["\r", <<0>>]),
      "#{path}: source is not canonical UTF-8/LF text"
    )

    case Code.string_to_quoted!(source, token_metadata: true, columns: true) do
      {:defmodule, _, [{:__aliases__, _, ^module}, [do: body]]} ->
        {String.split(source, "\n"), expressions(body)}

      _other ->
        throw({:refused, "#{path}: expected one registered module"})
    end
  end

  defp definition!(forms, kind, name, arity, path) do
    found =
      for {^kind, metadata, [head, [do: body]]} <- forms,
          {^name, _, arguments} <- [unguarded(head)],
          (is_list(arguments) and length(arguments) == arity) or
            (is_nil(arguments) and arity == 0),
          do: {metadata, body}

    case found do
      [{metadata, body}] ->
        first = Keyword.fetch!(metadata, :line)
        last = metadata |> Keyword.fetch!(:end) |> Keyword.fetch!(:line)
        %{first: first, last: last, body: body}

      _other ->
        throw({:refused, "#{path}: #{name}/#{arity} is missing or duplicated"})
    end
  end

  defp unguarded({:when, _, [head | _guards]}), do: head
  defp unguarded(head), do: head

  defp occurrence!(lines, definition, expected_line, path) do
    found =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, number} ->
        number >= definition.first and number <= definition.last and
          String.trim(line) == expected_line
      end)

    case found do
      [{line, number}] -> {path, number, line}
      _other -> throw({:refused, "#{path}: registered construction is missing or duplicated"})
    end
  end

  defp expressions({:__block__, _, expressions}), do: expressions
  defp expressions(expression), do: [expression]
  defp expected(source), do: source |> Code.string_to_quoted!() |> normalized()

  defp normalized(ast) do
    Macro.prewalk(ast, fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      other -> other
    end)
  end

  defp require!(true, _reason), do: :ok
  defp require!(false, reason), do: throw({:refused, reason})
end

case System.argv() do
  [root, input] ->
    case File.read(input) do
      {:ok, matches} ->
        case Loopex.M0ChildEnvironmentCheck.check(root, matches) do
          {:ok, count} ->
            IO.puts("M0 child-environment occurrences OK: #{count}")

          {:error, reason} ->
            IO.puts(:stderr, reason)
            System.halt(1)
        end

      {:error, _reason} ->
        IO.puts(:stderr, "child-environment matcher input unavailable")
        System.halt(2)
    end

  _other ->
    IO.puts(:stderr, "usage: m0-child-env-check.exs <checkout> <git-match-file>")
    System.halt(2)
end

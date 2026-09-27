defmodule Loopex.Executor.Local.ReadOnlyTools do
  @moduledoc false
  alias Loopex.Executor.Local.{CodingTools, ToolGlob}
  @kinds %{"loopex.grep" => :grep, "loopex.find" => :find, "loopex.ls" => :ls}
  @counters [:invalid_name, :too_large, :invalid_utf8, :changed, :unreadable]
  @file_limit 1_048_576
  @total_file_limit 16_777_216

  def arguments(id, arguments) when is_map(arguments) do
    kind = Map.fetch!(@kinds, id)

    allowed =
      case kind do
        :grep -> ["pattern", "path", "glob"]
        :find -> ["pattern", "path"]
        :ls -> ["path", "recursive"]
      end

    with true <- Enum.all?(Map.keys(arguments), &(&1 in allowed)),
         path = Map.get(arguments, "path", "."),
         true <- valid_string?(path),
         {:ok, matcher} <- matcher(kind, arguments),
         {:ok, filter} <- filter(kind, arguments),
         recursive = Map.get(arguments, "recursive", false),
         true <- is_boolean(recursive) do
      {:ok, %{kind: kind, path: path, matcher: matcher, filter: filter, recursive: recursive}}
    else
      _ -> {:error, :invalid_tool_arguments}
    end
  end

  def arguments(_, _), do: {:error, :invalid_tool_arguments}

  def validate_path(workspace, %{kind: kind} = arguments) when kind in [:grep, :find, :ls] do
    with {:ok, root} <- CodingTools.resolve(workspace, ".") do
      case requested_path(root, arguments.path) do
        {:error, :escape} -> {:error, :invalid_tool_arguments}
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  def validate_path(_, _), do: :ok

  defp valid_string?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp matcher(:ls, _), do: {:ok, nil}

  defp matcher(kind, arguments) do
    pattern = Map.get(arguments, "pattern")

    if valid_string?(pattern) do
      if kind == :grep, do: Regex.compile(pattern, "u"), else: ToolGlob.compile(pattern)
    else
      {:error, :invalid_pattern}
    end
  end

  defp filter(:grep, %{"glob" => glob}) do
    if valid_string?(glob), do: ToolGlob.compile(glob), else: {:error, :invalid_glob}
  end

  defp filter(_, _), do: {:ok, nil}

  def execute(workspace, arguments, output_limit) do
    with {:ok, root} <- CodingTools.resolve(workspace, "."),
         {:ok, path} <- requested_path(root, arguments.path),
         {:ok, info} <- File.lstat(path, time: :posix) do
      state = %{
        root: root,
        arguments: arguments,
        records: [],
        output_bytes: 0,
        output_limit: max(0, min(output_limit, 16_384) - 107),
        result_count: 0,
        entries: 0,
        path_bytes: 0,
        file_bytes: 0,
        truncated: false,
        halt: false,
        pending: :gb_trees.empty(),
        skips: Map.new(@counters, &{&1, 0})
      }

      result =
        if info.type == :directory,
          do: directory(state, path, info, 0, true),
          else: entry(state, path, info, 0, true)

      case result do
        {:error, :root_unavailable} -> failed(arguments.kind)
        state -> {:completed, output(walk(state))}
      end
    else
      {:error, :escape} -> {:failed, "requested path is outside the workspace"}
      _ -> failed(arguments.kind)
    end
  end

  # Concept: a final link is an entry, while every parent must remain inside.
  # Technical depth: lstat samples every segment without following the final
  # link; parent resolution narrows ordinary races but does not pin a directory.
  defp requested_path(root, requested) do
    candidate = Path.expand(requested, root)

    if contained?(candidate, root) do
      relative = Path.relative_to(candidate, root)
      segments = if relative == ".", do: [], else: Path.split(relative)
      inspect_segments(root, root, segments)
    else
      {:error, :escape}
    end
  end

  defp inspect_segments(_, path, []), do: {:ok, path}

  defp inspect_segments(root, parent, [segment | rest]) do
    with :ok <- parent_contained(root, parent),
         path = Path.join(parent, segment),
         {:ok, info} <- File.lstat(path, time: :posix) do
      if rest == [] do
        {:ok, path}
      else
        if info.type == :directory do
          inspect_segments(root, path, rest)
        else
          case parent_contained(root, path) do
            {:error, :escape} -> {:error, :escape}
            _ -> {:error, :unavailable}
          end
        end
      end
    end
  end

  defp parent_contained(root, parent) do
    case CodingTools.resolve(root, parent) do
      {:ok, resolved} -> if contained?(resolved, root), do: :ok, else: {:error, :escape}
      {:error, {:path_escapes_workspace, _}} -> {:error, :escape}
      _ -> {:error, :unavailable}
    end
  end

  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp relative(state, path), do: Path.relative_to(path, state.root)
  defp identity(info), do: {info.major_device, info.inode, info.type}
  defp file_identity(info), do: {info.major_device, info.inode, info.size}

  def classify(%File.Stat{type: :regular}), do: :regular
  def classify(%File.Stat{type: :directory}), do: :directory
  def classify(%File.Stat{type: :symlink}), do: :symlink
  def classify(%File.Stat{}), do: :special

  defp directory(state, path, before, depth, root?) do
    with :ok <- parent_contained(state.root, path),
         {:ok, names} <- :file.list_dir_all(String.to_charlist(path)),
         {:ok, after_info} <- File.lstat(path, time: :posix),
         true <- identity(before) == identity(after_info) do
      names
      |> Enum.map(&raw_name/1)
      |> Enum.sort()
      |> Enum.reduce(state, fn name, acc ->
        child = Path.join(path, name)
        %{acc | pending: :gb_trees.insert(child, depth + 1, acc.pending)}
      end)
    else
      false -> unavailable(state, root?, :changed)
      _ -> unavailable(state, root?, :unreadable)
    end
  end

  # Concept: result ordering includes the slash between a directory and child.
  # Technical depth: the frontier orders full raw paths, so `a-` precedes
  # `a/x` even though enumerating `a` precedes inspecting `a-`. Only admitted
  # directories are enumerated; this is not a whole-tree inventory.
  defp walk(%{halt: true} = state), do: state

  defp walk(state) do
    if :gb_trees.is_empty(state.pending) do
      state
    else
      {path, depth, pending} = :gb_trees.take_smallest(state.pending)
      next = count_entry(%{state | pending: pending}, path)

      next =
        cond do
          next.halt -> next
          not String.valid?(Path.basename(path)) -> skip(next, :invalid_name)
          true -> inspect_entry(next, path, depth)
        end

      walk(next)
    end
  end

  defp raw_name(name) when is_binary(name), do: name
  defp raw_name(name), do: List.to_string(name)

  defp count_entry(state, path) do
    bytes = byte_size(relative(state, path))

    if state.entries + 1 > 10_000 or state.path_bytes + bytes > 8_388_608,
      do: %{state | truncated: true, halt: true},
      else: %{state | entries: state.entries + 1, path_bytes: state.path_bytes + bytes}
  end

  defp inspect_entry(state, path, depth) do
    with :ok <- parent_contained(state.root, Path.dirname(path)),
         {:ok, info} <- File.lstat(path, time: :posix) do
      entry(state, path, info, depth, false)
    else
      _ -> skip(state, :unreadable)
    end
  end

  defp entry(state, path, info, depth, root?) do
    state = if root?, do: count_entry(state, path), else: state

    if state.halt do
      state
    else
      next =
        case state.arguments.kind do
          :grep ->
            if classify(info) == :regular and
                 matches?(state.arguments.filter, relative(state, path)),
               do: grep(state, path, info, root?),
               else: state

          :find ->
            if matches?(state.arguments.matcher, relative(state, path)),
              do: path_record(state, path, false),
              else: state

          :ls ->
            path_record(state, path, info.type == :directory)
        end

      case next do
        {:error, _} ->
          next

        next ->
          recurse? = state.arguments.kind != :ls or state.arguments.recursive
          limit = if state.arguments.kind == :ls, do: 8, else: 32

          cond do
            next.halt -> next
            info.type != :directory or not recurse? -> next
            depth >= limit -> %{next | truncated: true}
            true -> directory(next, path, info, depth, false)
          end
      end
    end
  end

  defp matches?(nil, _), do: true
  defp matches?(matcher, path), do: Regex.match?(matcher, path)

  defp path_record(state, path, directory?) do
    path = relative(state, path) <> if(directory?, do: "/", else: "")
    record(state, "P\t" <> encode(path) <> "\n")
  end

  defp record(state, bytes) do
    maximum = if state.arguments.kind == :grep, do: 1000, else: 2000

    if state.result_count == maximum or state.output_bytes + byte_size(bytes) > state.output_limit do
      %{state | truncated: true}
    else
      %{
        state
        | records: [bytes | state.records],
          result_count: state.result_count + 1,
          output_bytes: state.output_bytes + byte_size(bytes)
      }
    end
  end

  defp grep(state, path, info, root?) do
    if info.size > @file_limit do
      skip(state, :too_large)
    else
      case :file.open(String.to_charlist(path), [:read, :binary]) do
        {:ok, handle} ->
          try do
            case verify_file(handle, path, info) do
              :ok -> read_file(state, handle, path, info, root?)
              {:error, reason} -> unavailable(state, root?, reason)
            end
          after
            :file.close(handle)
          end

        _ ->
          unavailable(state, root?, :unreadable)
      end
    end
  end

  defp verify_file(handle, path, before) do
    with {:ok, handle_info} <- :file.read_file_info(handle, [{:time, :posix}]),
         {:ok, path_info} <- File.lstat(path, time: :posix) do
      handle_info = File.Stat.from_record(handle_info)

      if same_file?(before, handle_info, path_info), do: :ok, else: {:error, :changed}
    else
      _ -> {:error, :unreadable}
    end
  end

  def same_file?(before, handle, path) do
    handle.type == :regular and path.type == :regular and
      file_identity(handle) == file_identity(before) and
      file_identity(path) == file_identity(before)
  end

  defp read_file(state, handle, path, info, root?) do
    {consumed, staged, status} = read_lines(state, state, handle, path, 0, "", 1, false)

    consumed =
      case status do
        :too_large -> skip(consumed, :too_large)
        :invalid_utf8 -> skip(consumed, :invalid_utf8)
        :truncated_invalid_utf8 -> skip(consumed, :invalid_utf8)
        _ -> consumed
      end

    case verify_file(handle, path, info) do
      {:error, reason} ->
        unavailable(consumed, root?, reason)

      :ok ->
        case status do
          :unreadable ->
            unavailable(consumed, root?, :unreadable)

          :too_large ->
            consumed

          :truncated ->
            staged

          :invalid_utf8 ->
            consumed

          :truncated_invalid_utf8 ->
            consumed

          :ok ->
            staged
        end
    end
  end

  # Concept: every observed byte spends the shared walk budget.
  # Technical depth: read at most the remaining allowance plus one witness byte;
  # the witness is counted but never retained, including for discarded files.
  defp read_lines(consumed, staged, handle, path, size, carry, line_number, invalid?) do
    amount = min(8192, min(@file_limit - size + 1, @total_file_limit - consumed.file_bytes + 1))

    case :file.read(handle, amount) do
      :eof ->
        {staged, invalid?} =
          if carry != "",
            do: line(staged, path, carry, line_number, invalid?),
            else: {staged, invalid?}

        {consumed, staged, if(invalid?, do: :invalid_utf8, else: :ok)}

      {:error, _} ->
        {consumed, staged, :unreadable}

      {:ok, bytes} ->
        total = consumed.file_bytes + byte_size(bytes)
        size = size + byte_size(bytes)
        consumed = %{consumed | file_bytes: total}
        staged = %{staged | file_bytes: total}

        cond do
          total > @total_file_limit ->
            # The final observed byte is the witness, never line content.
            bytes = binary_part(bytes, 0, byte_size(bytes) - 1)

            {staged, carry, _number, invalid?} =
              chunk(staged, path, carry <> bytes, line_number, invalid?)

            invalid? = invalid? or not valid_utf8_prefix?(carry)

            consumed = %{consumed | truncated: true, halt: true}
            staged = %{staged | truncated: true, halt: true}

            if invalid?,
              do: {consumed, staged, :truncated_invalid_utf8},
              else: {consumed, staged, :truncated}

          size > @file_limit ->
            {consumed, staged, :too_large}

          true ->
            {staged, carry, line_number, invalid?} =
              chunk(staged, path, carry <> bytes, line_number, invalid?)

            read_lines(consumed, staged, handle, path, size, carry, line_number, invalid?)
        end
    end
  end

  # Concept: a byte cap can cut a valid scalar, but cannot hide malformed bytes.
  # Technical depth: completed lines were checked by chunk/5. Validate its
  # unfinished carry as a prefix; an incomplete suffix is admitted only when a
  # canonical continuation could complete it. OTP also labels impossible
  # overlong, surrogate and out-of-range prefixes incomplete before full width.
  defp valid_utf8_prefix?(bytes) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      valid when is_binary(valid) -> true
      {:error, _, _} -> false
      {:incomplete, _, suffix} -> valid_incomplete_scalar?(suffix)
    end
  end

  defp valid_incomplete_scalar?(<<0xE0>>), do: true
  defp valid_incomplete_scalar?(<<0xF0>>), do: true

  defp valid_incomplete_scalar?(<<leading, _::binary>> = suffix) do
    width =
      cond do
        leading in 0xC2..0xDF -> 2
        leading in 0xE0..0xEF -> 3
        leading in 0xF0..0xF4 -> 4
        true -> 0
      end

    width > byte_size(suffix) and
      String.valid?(suffix <> :binary.copy(<<0x80>>, width - byte_size(suffix)))
  end

  defp chunk(state, path, bytes, number, invalid?) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        {state, bytes, number, invalid?}

      {position, 1} ->
        text = binary_part(bytes, 0, position)
        rest = binary_part(bytes, position + 1, byte_size(bytes) - position - 1)
        {state, invalid?} = line(state, path, text, number, invalid?)
        chunk(state, path, rest, number + 1, invalid?)
    end
  end

  defp line(state, _path, _text, _number, true), do: {state, true}

  defp line(state, path, text, number, false) do
    if String.valid?(text) do
      state =
        if Regex.match?(state.arguments.matcher, text),
          do:
            record(
              state,
              "M\t" <>
                encode(relative(state, path)) <>
                "\t" <> Integer.to_string(number) <> "\t" <> encode(text) <> "\n"
            ),
          else: state

      {state, false}
    else
      {state, true}
    end
  end

  defp unavailable(_, true, _), do: {:error, :root_unavailable}
  defp unavailable(state, false, reason), do: skip(state, reason)
  defp skip(state, reason), do: put_in(state.skips[reason], min(10_000, state.skips[reason] + 1))
  defp failed(kind), do: {:failed, "#{kind} failed: requested path unavailable"}

  def encode(text) do
    for <<byte <- text>>, into: "" do
      if byte in 0x20..0x7E and byte != ?%,
        do: <<byte>>,
        else:
          "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
    end
  end

  defp output(state) do
    skipped =
      if Enum.any?(@counters, &(state.skips[&1] > 0)),
        do: "N\tskipped\t" <> Enum.map_join(@counters, "\t", &"#{&1}=#{state.skips[&1]}") <> "\n",
        else: ""

    truncated = if state.truncated, do: "N\ttruncated\n", else: ""
    state.records |> Enum.reverse() |> Enum.concat([skipped, truncated]) |> IO.iodata_to_binary()
  end
end

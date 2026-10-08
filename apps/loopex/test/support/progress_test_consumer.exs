defmodule Loopex.ProgressTestConsumer do
  @moduledoc false
  alias Loopex.ProgressSink

  # Concept: the test caller is the real sink-taking owner.
  # Technical depth: observations retain their leases through every assertion
  # copy. Owner DOWN ends this native fixture lifetime; no external write or
  # cleanup success is inferred. Buffers cannot exceed charged arena custody.
  def open_sink do
    {:ok, sink} = ProgressSink.open()
    Process.put({__MODULE__, :sinks}, Process.get({__MODULE__, :sinks}, []) ++ [sink])
    sink
  end

  def route(fixture, header \\ %{}) do
    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{}, command_id: "progress-domain-fixture")

    {:ok, %{control: control}} = Loopex.Runtime.children(fixture.runtime)
    entry = :sys.get_state(control).sessions[session]
    state = :sys.get_state(entry.coordinator)
    {state.progress_sink, session, control, entry.owner, header}
  end

  defmacro assert_progress(pattern, timeout \\ 100, message \\ nil) do
    {native, legacy} = patterns(pattern)
    native = probe_pattern(native)

    quote do
      result =
        Loopex.ProgressTestConsumer.matching(
          fn value ->
            case value do
              unquote(native) -> true
              _ -> false
            end
          end,
          unquote(timeout)
        )

      ExUnit.Assertions.assert(
        result != :empty,
        unquote(message) || "expected a leased progress item"
      )

      unquote(pattern) = unquote(legacy)
    end
  end

  defmacro refute_progress(pattern, timeout \\ 100, message \\ nil) do
    {native, _legacy} = patterns(pattern)
    native = probe_pattern(native)

    quote do
      result =
        Loopex.ProgressTestConsumer.matching(
          fn value ->
            case value do
              unquote(native) -> true
              _ -> false
            end
          end,
          unquote(timeout)
        )

      ExUnit.Assertions.assert(
        result == :empty,
        unquote(message) || "unexpected leased progress item"
      )
    end
  end

  defmacro refute_progress_received(pattern) do
    quote do: refute_progress(unquote(pattern), 0)
  end

  defp probe_pattern({:^, _metadata, _arguments} = pinned), do: pinned

  defp probe_pattern({:_, _metadata, _context} = wildcard), do: wildcard

  defp probe_pattern({name, metadata, context})
       when is_atom(name) and is_list(metadata) and (is_atom(context) or is_nil(context)),
       do: {String.to_atom("_" <> Atom.to_string(name)), metadata, context}

  defp probe_pattern(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&probe_pattern/1) |> List.to_tuple()

  defp probe_pattern(list) when is_list(list), do: Enum.map(list, &probe_pattern/1)
  defp probe_pattern(value), do: value

  defp patterns({:{}, _metadata, [:loopex_progress, session, item]}),
    do:
      {quote(do: {unquote(session), unquote(item)}),
       quote(do: {:loopex_progress, elem(result, 0), elem(result, 1)})}

  defp patterns({:loopex_progress, item}),
    do: {quote(do: {_session, unquote(item)}), quote(do: {:loopex_progress, elem(result, 1)})}

  defp patterns({:{}, _metadata, [:loopex_progress, item]}),
    do: {quote(do: {_session, unquote(item)}), quote(do: {:loopex_progress, elem(result, 1)})}

  def matching(predicate, timeout),
    do: find(predicate, System.monotonic_time(:millisecond) + timeout)

  defp find(predicate, cutoff) do
    collect()
    buffer = Process.get({__MODULE__, :buffer}, [])

    case Enum.find_index(buffer, fn {_sink, _lease, session, item} ->
           predicate.({session, item})
         end) do
      nil ->
        remaining = max(cutoff - System.monotonic_time(:millisecond), 0)

        if remaining == 0 do
          :empty
        else
          receive do
            {:loopex_progress_ready, sink} ->
              # Return the actual notification so take owns its acknowledgement.
              send(self(), {:loopex_progress_ready, sink})
              find(predicate, cutoff)
          after
            remaining -> :empty
          end
        end

      index ->
        {sink, lease, session, item} = Enum.at(buffer, index)
        Process.put({__MODULE__, :buffer}, List.delete_at(buffer, index))

        Process.put({__MODULE__, :observed}, [
          {sink, lease} | Process.get({__MODULE__, :observed}, [])
        ])

        {session, item}
    end
  end

  def drain(timeout \\ 0) do
    collect_until(System.monotonic_time(:millisecond) + timeout)
    buffer = Process.get({__MODULE__, :buffer}, [])
    Process.put({__MODULE__, :buffer}, [])
    leases = Enum.map(buffer, fn {sink, lease, _session, _item} -> {sink, lease} end)
    Process.put({__MODULE__, :observed}, leases ++ Process.get({__MODULE__, :observed}, []))
    Enum.map(buffer, fn {_sink, _lease, _session, item} -> item end)
  end

  defp collect_until(cutoff) do
    collect()
    remaining = max(cutoff - System.monotonic_time(:millisecond), 0)

    if remaining > 0 do
      receive do
        {:loopex_progress_ready, sink} ->
          send(self(), {:loopex_progress_ready, sink})
          collect_until(cutoff)
      after
        remaining -> :ok
      end
    end
  end

  defp collect do
    for sink <- Process.get({__MODULE__, :sinks}, []), do: take_all(sink)
  end

  defp take_all(sink) do
    case ProgressSink.take(sink) do
      {:ok, lease, session, item} ->
        Process.put(
          {__MODULE__, :buffer},
          Process.get({__MODULE__, :buffer}, []) ++ [{sink, lease, session, item}]
        )

        take_all(sink)

      _ ->
        :ok
    end
  end
end

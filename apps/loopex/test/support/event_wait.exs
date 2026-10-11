defmodule Loopex.EventWait do
  @moduledoc """
  ## Concept

  Await an actor's own message with no test-clock window. A fixed window
  started by the test can expire before a freshly spawned process, task or
  child VM is even scheduled, so a loaded host fails a correct product. These
  waits end on the awaited event; the case's ExUnit timeout is the outer bound.

  ## Technical depth

  `ExUnit.Assertions.assert_receive/3` accepts only an integer timeout.
  `await_receive/1` takes the same pattern (pins and a `when` guard included),
  blocks until a matching message arrives, binds the pattern's variables in the
  caller exactly as `assert_receive` does, and returns the message.
  """

  defmacro await_receive(pattern) do
    {match, guard} =
      case pattern do
        {:when, _, [match, guard]} -> {match, guard}
        match -> {match, true}
      end

    message = Macro.var(:message, __MODULE__)
    pattern_vars = bound_variables(match)

    # As in `assert_receive`, a guard's uses of pattern variables are carried
    # too, so a variable read only by the guard counts as used.
    vars =
      pattern_vars ++
        for {name, _, context} = var <- bound_variables(guard),
            Enum.any?(pattern_vars, &match?({^name, _, ^context}, &1)),
            do: var

    generated =
      Enum.map(vars, fn {name, meta, context} -> {name, [generated: true] ++ meta, context} end)

    quote do
      {unquote(message), unquote(vars)} =
        receive do
          unquote(match) = unquote(message) when unquote(guard) ->
            {unquote(message), unquote(generated)}
        end

      unquote(message)
    end
  end

  # The variables a pattern binds, as `assert_receive` collects them.
  defp bound_variables(match) do
    match
    |> Macro.prewalk([], fn
      {skip, _, [_]}, acc when skip in [:^, :@] ->
        {:ok, acc}

      {name, meta, context}, acc when is_atom(name) and is_atom(context) ->
        if String.starts_with?(Atom.to_string(name), "_"),
          do: {:ok, acc},
          else: {:ok, [{name, meta, context} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq_by(fn {name, _meta, context} -> {name, context} end)
  end
end

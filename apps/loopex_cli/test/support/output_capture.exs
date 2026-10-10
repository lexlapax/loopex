defmodule LoopexCli.Test.OutputCapture do
  @moduledoc false

  # Concept: a test reads a command's output from a target it owns.
  # Technical depth: the command acquires the in-memory target exclusively for
  # its own output owner; the test reads the exact bytes after that owner has
  # finished. No group leader or borrowed IO device is involved.

  alias LoopexCli.Output
  alias LoopexCli.Output.Memory

  @doc false
  def dispatch(argv, options \\ []) do
    {:ok, target} = Memory.start()

    try do
      result =
        LoopexCli.dispatch(argv, Keyword.put(options, :output_target, Memory.target(target)))

      {stdout, stderr} = Memory.contents(target)
      {result, stdout, stderr}
    after
      Memory.stop(target)
    end
  end

  # Concept: code that renders directly gets the same owned output.
  # Technical depth: the caller becomes the output's command; `finish/1` joins
  # it and returns the bytes. The native sink is unbound for one runtime.
  @doc false
  def open(options \\ []) do
    {:ok, target} = Memory.start()
    {:ok, output, sink} = Output.open(Memory.target(target), Output.acquisition(), options)
    previous = Output.put_current(output, sink)
    %{output: output, sink: sink, target: target, previous: previous}
  end

  @doc false
  def finish(%{output: output, target: target, previous: previous}) do
    :ok = Output.finish(output)
    Output.restore_current(previous)
    contents = Memory.contents(target)
    Memory.stop(target)
    contents
  end

  # Concept: render one block of code and return what it wrote.
  @doc false
  def capture(function, options \\ []) do
    capture = open(options)

    result =
      try do
        function.(capture)
      rescue
        error ->
          _ = Output.finish(capture.output)
          Output.restore_current(capture.previous)
          Memory.stop(capture.target)
          reraise error, __STACKTRACE__
      end

    {stdout, stderr} = finish(capture)
    {result, stdout, stderr}
  end

  # Concept: the bytes one block of code wrote to one destination.
  # Technical depth: commands dispatched inside the block reuse this process's
  # current output, so standard output and standard error stay one ordered
  # owner even when only one of them is inspected.
  @doc false
  def stdout(function), do: elem(capture(fn _ -> function.() end), 1)

  @doc false
  def stderr(function), do: elem(capture(fn _ -> function.() end), 2)
end

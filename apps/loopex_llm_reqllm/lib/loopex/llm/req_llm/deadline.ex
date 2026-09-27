defmodule Loopex.LLM.ReqLLM.Deadline do
  @moduledoc """
  ## Concept

  Preserve one committed deadline across the companion and in-process edges.

  ## Technical depth

  An invocation freezes one native time offset to convert its absolute system
  millisecond instant into monotonic time. Native instants retain fractional
  milliseconds. Only relative waits round upward, and expired waits return zero.
  Callers cap relative waits before passing them to timers.
  """

  @doc false
  def invocation_deadline(wall_milliseconds, native_offset)
      when is_integer(wall_milliseconds) and is_integer(native_offset) do
    System.convert_time_unit(wall_milliseconds, :millisecond, :native) - native_offset
  end

  @doc false
  def remaining_timeout(deadline, sampled_now)
      when is_integer(deadline) and is_integer(sampled_now) do
    remaining = deadline - sampled_now

    if remaining <= 0 do
      0
    else
      milliseconds = System.convert_time_unit(remaining, :native, :millisecond)

      if System.convert_time_unit(milliseconds, :millisecond, :native) < remaining do
        milliseconds + 1
      else
        milliseconds
      end
    end
  end
end

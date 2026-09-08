defmodule Loopex.LLM.ReqLLM.ProviderDeadlineTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.{ProviderBridge, ProviderCodec}

  test "one offset preserves the wall deadline despite separated-sample time and fractional native offsets" do
    # Fixed clock coordinates, not expectations copied from the implementation:
    # with wall = monotonic + 1000 ms, wall 1010 is monotonic 10 ms.
    # Sampling monotonic 2 ms and then wall 1005 ms would wrongly yield 7 ms.
    for {wall_ms, offset_us, expected_us} <- [
          {1010, 1_000_000, 10_000},
          {1010, 1_000_250, 9_750},
          {1010, 1_010_250, -250},
          {0, -1_000_250, 1_000_250}
        ] do
      assert ProviderBridge.invocation_deadline(wall_ms, native(offset_us)) == native(expected_us)
    end
  end

  test "positive native receive remainders cannot become zero or lose their final fraction" do
    # Integer milliseconds are a socket boundary, not the stored clock unit.
    for {remaining_us, expected_ms} <- [
          {-1, 0},
          {0, 0},
          {1, 1},
          {999, 1},
          {1000, 1},
          {1001, 2},
          {1999, 2},
          {2000, 2}
        ] do
      assert ProviderCodec.remaining_timeout(native(remaining_us - 5000), native(-5000)) ==
               expected_ms
    end
  end

  defp native(microseconds), do: System.convert_time_unit(microseconds, :microsecond, :native)
end

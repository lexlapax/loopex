defmodule LoopexProtocolTest do
  use ExUnit.Case, async: true

  test "the contract reports the umbrella's single version" do
    expected =
      [__DIR__, "..", "..", "..", "VERSION"]
      |> Path.join()
      |> File.read!()
      |> String.trim()

    assert LoopexProtocol.version() == expected
  end

  test "the contract application carries no dependency at runtime" do
    # ADR 0001 from the contract's own side, asserted against the compiled
    # application spec rather than the mix.exs text. An out-of-repository
    # extension author acquires exactly this closure, so what the built
    # application declares is the property that matters, not what the source said.
    Application.load(:loopex_protocol)
    declared = Application.spec(:loopex_protocol, :applications) || []

    assert Enum.sort(declared) == [:elixir, :kernel, :stdlib]
    refute :loopex in declared
  end
end

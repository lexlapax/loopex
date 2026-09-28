Code.require_file("support/ephemeral_ambient_fixture.ex", __DIR__)

defmodule LoopexComposition.Ephemeral.AmbientDisclosureTest do
  use ExUnit.Case, async: false

  test "a trusted host copy may reach a hosted tool result, but a provider echo cannot publish it" do
    {output, status} = LoopexComposition.Ephemeral.AmbientFixture.run_in_child()
    assert status == 0, output
    assert output =~ "EPHEMERAL_AMBIENT_DISCLOSURE_PASSED"
  end
end

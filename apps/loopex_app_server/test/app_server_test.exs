defmodule Loopex.AppServerTest do
  @moduledoc """
  ## Concept

  The foreground server declares the exact protocol generation it speaks, and is
  a client of a runtime rather than a second one.

  ## Technical depth

  Accepted ADR 0023 makes the generation an experimental named contract rather
  than a version number a caller can round up, so it is asserted literally: a
  build that changes it changes what every negotiated connection means. The
  dependency direction is checked here as well as in the oracle, because an
  application that reached back into a runtime's internals would still satisfy a
  role budget while breaking the direction the budget exists to protect.
  """

  use ExUnit.Case, async: true

  alias Loopex.AppServer

  test "the declared generation is the experimental session protocol, named exactly" do
    assert AppServer.generation() == "loopex.experimental/1"
  end

  test "the generation is a bounded plain binary, which is what a caller negotiates against" do
    generation = AppServer.generation()

    assert is_binary(generation)
    assert byte_size(generation) <= 64
    assert generation == String.trim(generation)
  end

  test "the application declares the client role and no external production dependency" do
    config = Mix.Project.config()

    assert config[:app] == :loopex_app_server
    assert config[:loopex_role] == :client

    # Every declared dependency is an umbrella sibling, so a build that includes
    # this application gains no external package because of it.
    assert Enum.all?(config[:deps], fn
             {_name, options} when is_list(options) -> Keyword.get(options, :in_umbrella) == true
             _other -> false
           end)

    assert Enum.sort(Enum.map(config[:deps], &elem(&1, 0))) ==
             [:loopex, :loopex_composition, :loopex_protocol]
  end
end
